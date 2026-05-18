"""Admin patch-runner — v2 c git auto-snapshot перед/после запуска patch'a.

Юра msg 17477: «фича чтобы боту можно было присылать скрипты в особую папку,
потом /list_patches + /run_patch <name|n> запускает с live-стримингом логов».

Юра msg 17482: «перед каждым обновлением push'ить старую версию в GitHub».

Команды:
    /list_patches              — список файлов в ~/ai-assistant/patches-incoming/
    /run_patch <filename>      — git snapshot → запуск patch → git snapshot (если rc=0)
    /run_patch <n>             — то же по номеру из /list_patches
    /rm_patch <filename>       — удалить (path-traversal safe)

Git snapshots:
  - PRE-snapshot всегда перед запуском (warn-only если fail, не блокирует patch)
  - POST-snapshot только при rc=0
  - Repo root определяется как parent от patches_dir
  - Branch: main (override через GIT_BRANCH env var)
  - Push: origin <branch>
"""

from __future__ import annotations

import asyncio
import time
from datetime import datetime
from pathlib import Path

from aiogram import Bot, Dispatcher
from aiogram.filters import Command
from aiogram.types import Message


_RUNNING_PATCHES: dict[str, float] = {}
_PATCH_RUNNER_LOCK = asyncio.Lock()
_ALLOWED_EXT = {".sh", ".py", ".bash", ".patch"}
_MAX_FILES_IN_LIST = 30
_BATCH_SECONDS = 5
_MAX_BATCH_CHARS = 3500


def register_patch_runner(dp: Dispatcher, bot: Bot, patches_dir: Path, admin_id: int) -> None:
    patches_dir.mkdir(parents=True, exist_ok=True)

    def _list_files() -> list[Path]:
        files = [f for f in patches_dir.glob("*") if f.is_file()]
        files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
        return files

    @dp.message(Command("list_patches"))
    async def cmd_list(message: Message) -> None:
        if message.from_user is None or message.from_user.id != admin_id:
            return
        files = _list_files()
        if not files:
            await message.answer(
                f"📂 Папка пуста: <code>{patches_dir}</code>\n\n"
                "Пришли .sh / .py файл боту — он автоматически попадёт сюда."
            )
            return
        lines = [f"📂 <b>Patches inbox</b> (<code>{patches_dir.name}/</code>):"]
        for i, f in enumerate(files[:_MAX_FILES_IN_LIST], start=1):
            size_kb = f.stat().st_size / 1024
            mtime = time.strftime("%m-%d %H:%M", time.localtime(f.stat().st_mtime))
            running = " ▶️" if str(f) in _RUNNING_PATCHES else ""
            lines.append(f"<b>{i}.</b> <code>{f.name}</code>  {size_kb:.1f}KB  {mtime}{running}")
        if len(files) > _MAX_FILES_IN_LIST:
            lines.append(f"\n…и ещё {len(files) - _MAX_FILES_IN_LIST} файлов")
        lines.append("\nЗапуск: <code>/run_patch имя</code> или <code>/run_patch 1</code>")
        lines.append("Удалить: <code>/rm_patch имя</code>")
        await message.answer("\n".join(lines))

    @dp.message(Command("run_patch"))
    async def cmd_run(message: Message) -> None:
        if message.from_user is None or message.from_user.id != admin_id:
            return
        text = (message.text or "").strip()
        parts = text.split(maxsplit=1)
        if len(parts) < 2 or not parts[1].strip():
            await message.answer(
                "Использование: <code>/run_patch &lt;имя или номер&gt;</code>\n\n"
                "Сначала <code>/list_patches</code> — увидеть что доступно."
            )
            return
        arg = parts[1].strip()
        files = _list_files()
        target: Path | None = None
        if arg.isdigit():
            idx = int(arg) - 1
            if 0 <= idx < len(files):
                target = files[idx]
        if target is None:
            for f in files:
                if f.name == arg:
                    target = f
                    break
        if target is None:
            matches = [f for f in files if f.name.startswith(arg)]
            if len(matches) == 1:
                target = matches[0]
            elif len(matches) > 1:
                preview = "\n".join(f"• <code>{f.name}</code>" for f in matches[:10])
                await message.answer(f"Несколько матчей по '{arg}':\n{preview}\n\nУточни имя или используй номер.")
                return
        if target is None:
            await message.answer(f"❌ Не нашёл файл: <code>{arg}</code>\n\n<code>/list_patches</code> — список.")
            return
        if target.suffix not in _ALLOWED_EXT:
            await message.answer(
                f"❌ Запрещённое расширение: <code>{target.suffix}</code>.\n"
                f"Разрешены: {', '.join(sorted(_ALLOWED_EXT))}"
            )
            return
        try:
            target.resolve().relative_to(patches_dir.resolve())
        except (ValueError, RuntimeError):
            await message.answer("⛔ Path traversal detected.")
            return

        async with _PATCH_RUNNER_LOCK:
            if str(target) in _RUNNING_PATCHES:
                await message.answer(f"⚠️ <code>{target.name}</code> уже запущен.")
                return
            _RUNNING_PATCHES[str(target)] = time.time()
        try:
            await _run_patch_streaming(bot, message.chat.id, target, patches_dir.parent)
        finally:
            _RUNNING_PATCHES.pop(str(target), None)

    @dp.message(Command("rm_patch"))
    async def cmd_rm(message: Message) -> None:
        if message.from_user is None or message.from_user.id != admin_id:
            return
        text = (message.text or "").strip()
        parts = text.split(maxsplit=1)
        if len(parts) < 2 or not parts[1].strip():
            await message.answer("Использование: <code>/rm_patch &lt;имя&gt;</code>")
            return
        target = patches_dir / parts[1].strip()
        try:
            target.resolve().relative_to(patches_dir.resolve())
        except (ValueError, RuntimeError):
            await message.answer("⛔ Path traversal detected.")
            return
        if not target.exists() or not target.is_file():
            await message.answer(f"❌ Не найден: <code>{target.name}</code>")
            return
        target.unlink()
        await message.answer(f"🗑 Удалён: <code>{target.name}</code>")


async def _run_git(args: list[str], cwd: Path, timeout: float = 60) -> tuple[int, str]:
    """git <args> в cwd с timeout. Возвращает (rc, combined-output)."""
    try:
        proc = await asyncio.create_subprocess_exec(
            "git", *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            cwd=str(cwd),
        )
        try:
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        except asyncio.TimeoutError:
            proc.kill()
            return 124, f"git {args[0]} timeout after {timeout}s"
        return proc.returncode, stdout.decode("utf-8", errors="replace")
    except FileNotFoundError:
        return 127, "git binary not found in PATH"
    except Exception as e:
        return 1, f"git {args[0]} unexpected error: {e}"


async def _git_snapshot(repo_root: Path, label: str) -> tuple[bool, str]:
    """git add -A → commit (if changes) → push origin <branch>."""
    import os as _os
    branch = _os.environ.get("GIT_BRANCH", "main")

    if not (repo_root / ".git").exists():
        return False, f"repo_root {repo_root} не git-репозиторий (.git не найден)"

    rc, out = await _run_git(["add", "-A"], repo_root)
    if rc != 0:
        return False, f"git add failed (rc={rc}): {out[:300]}"

    # diff --cached --quiet: rc=0 → changes есть, rc=1 → нет
    rc_diff, _ = await _run_git(["diff", "--cached", "--quiet"], repo_root)
    if rc_diff == 0:
        return True, "(no changes — workspace clean)"

    rc, out = await _run_git(["commit", "-m", label], repo_root)
    if rc != 0:
        return False, f"git commit failed (rc={rc}): {out[:300]}"

    rc, push_out = await _run_git(["push", "origin", branch], repo_root, timeout=120)
    if rc != 0:
        return False, f"git push failed (rc={rc}): {push_out[:400]}"

    # short stat for response
    short = "\n".join(push_out.strip().split("\n")[:5])
    return True, f"commit + push OK\n{short}"


async def _run_patch_streaming(bot: Bot, chat_id: int, target: Path, repo_root: Path) -> None:
    # ─── 1. PRE-snapshot ────────────────────────────────────────────────────
    ts_iso = datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
    pre_label = f"pre-patch: {target.name} @ {ts_iso}"
    await bot.send_message(chat_id, f"📸 Git snapshot pre-patch: <code>{repo_root}</code>")
    ok, info = await _git_snapshot(repo_root, pre_label)
    if ok:
        info_escaped = info.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        await bot.send_message(chat_id, f"✅ Snapshot:\n<pre>{info_escaped[:500]}</pre>")
    else:
        info_escaped = info.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        await bot.send_message(
            chat_id,
            f"⚠️ Snapshot не удался (patch всё равно запущу):\n<pre>{info_escaped[:500]}</pre>"
        )

    # ─── 2. Run patch ───────────────────────────────────────────────────────
    await bot.send_message(chat_id, f"▶️ Запускаю <code>{target.name}</code>…")
    proc = await asyncio.create_subprocess_exec(
        "bash", str(target),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
        cwd=str(target.parent),
    )
    buffer: list[str] = []
    last_send = time.time()
    total_chars = 0

    async def flush() -> None:
        nonlocal buffer, total_chars
        if not buffer:
            return
        text = "\n".join(buffer)
        if len(text) > _MAX_BATCH_CHARS:
            text = text[:_MAX_BATCH_CHARS] + "\n…[обрезано]"
        escaped = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        try:
            await bot.send_message(chat_id, f"<pre>{escaped}</pre>")
        except Exception:
            try:
                await bot.send_message(chat_id, text[:_MAX_BATCH_CHARS])
            except Exception:
                pass
        buffer = []
        total_chars = 0

    assert proc.stdout is not None
    while True:
        try:
            line = await asyncio.wait_for(proc.stdout.readline(), timeout=_BATCH_SECONDS)
        except asyncio.TimeoutError:
            if buffer and (time.time() - last_send) >= _BATCH_SECONDS:
                await flush()
                last_send = time.time()
            continue
        if not line:
            break
        decoded = line.decode("utf-8", errors="replace").rstrip()
        buffer.append(decoded)
        total_chars += len(decoded) + 1
        now = time.time()
        if (now - last_send) >= _BATCH_SECONDS or total_chars >= _MAX_BATCH_CHARS:
            await flush()
            last_send = now

    await flush()
    rc = await proc.wait()

    # ─── 3. POST-snapshot (only if rc=0) ────────────────────────────────────
    if rc == 0:
        await bot.send_message(chat_id, f"✅ <code>{target.name}</code> завершён (rc=0).")
        post_label = f"post-patch: {target.name} rc=0 @ {ts_iso}"
        ok2, info2 = await _git_snapshot(repo_root, post_label)
        info2_escaped = info2.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        if ok2:
            await bot.send_message(chat_id, f"📸 Post-snapshot:\n<pre>{info2_escaped[:500]}</pre>")
        else:
            await bot.send_message(chat_id, f"⚠️ Post-snapshot failed:\n<pre>{info2_escaped[:500]}</pre>")
    else:
        await bot.send_message(chat_id, f"❌ <code>{target.name}</code> завершён с <b>rc={rc}</b>. Post-snapshot пропускаю.")
