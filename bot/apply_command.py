"""Admin /apply <filename> command.

Лёгкий и безопасный self-update механизм:
- валидирует имя файла (только basename, .sh, без path traversal)
- проверяет размер и существование в ~/Documents
- bash -n синтаксис-чек (если упало — abort с диагностикой)
- shellcheck (если установлен) — warning, не блокирует
- chmod +x
- снимает snapshot bot.py + .env + tools/ → ~/Documents/backups/snapshot-{ts}.tar.gz
- запускает с timeout=600s через asyncio.create_subprocess_exec
- если rc=0 — пишет /tmp/home-ai-bot-restart-notice.json и
  через detached subprocess вызывает `systemctl --user restart`
- on_startup хук бота читает notice и шлёт админу «🟢 поднят».

Конфиг через env:
    BOT_REPO_DIR        — корень репо бота (default: ~/ai-assistant)
    BOT_SERVICE_NAME    — имя systemd-юнита (default: home-ai-bot.service)
    BOT_ADMIN_IDS       — comma-separated список telegram user_id админов
    APPLY_MAX_FILE_MB   — лимит размера .sh (default 5)
    APPLY_TIMEOUT_SEC   — таймаут выполнения (default 600)
"""

import asyncio
import json
import os
import re
import shutil
import subprocess
import time
from datetime import datetime
from pathlib import Path

from aiogram import Bot, Dispatcher
from aiogram.filters import Command
from aiogram.types import Message

DOCUMENTS_DIR = Path.home() / "Documents"
BACKUP_DIR = DOCUMENTS_DIR / "backups"
BOT_REPO = Path(os.environ.get("BOT_REPO_DIR", str(Path.home() / "ai-assistant")))
SERVICE_NAME = os.environ.get("BOT_SERVICE_NAME", "home-ai-bot.service")
MAX_FILE_MB = int(os.environ.get("APPLY_MAX_FILE_MB", "5"))
RUN_TIMEOUT = int(os.environ.get("APPLY_TIMEOUT_SEC", "600"))
MAX_FILE_SIZE = MAX_FILE_MB * 1024 * 1024
FILENAME_RE = re.compile(r"^[A-Za-z0-9._-]+\.sh$")
STARTUP_NOTICE_FILE = Path("/tmp/home-ai-bot-restart-notice.json")


def _parse_admin_ids() -> set:
    raw = os.environ.get("BOT_ADMIN_IDS", "")
    out = set()
    for tok in raw.replace(";", ",").split(","):
        tok = tok.strip()
        if tok and tok.lstrip("-").isdigit():
            out.add(int(tok))
    return out


def _validate_name(name):
    name = name.strip()
    if not name:
        return False, "пустое имя файла"
    if "/" in name or "\\" in name or ".." in name:
        return False, "недопустимые символы в имени (path traversal)"
    if not FILENAME_RE.match(name):
        return False, "имя должно соответствовать [A-Za-z0-9._-]+.sh"
    return True, ""


def _tail(s, n=700):
    s = s or ""
    if len(s) <= n:
        return s
    return "...\n" + s[-n:]


def _git_rev(repo):
    try:
        out = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, timeout=5,
        )
        if out.returncode == 0:
            return out.stdout.strip() or "no-rev"
    except Exception:
        pass
    return "no-git"


def _make_backup(ts):
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    snap = BACKUP_DIR / f"snapshot-{ts}.tar.gz"
    targets = []
    bot_py = BOT_REPO / "bot" / "bot.py"
    env_file = BOT_REPO / ".env"
    tools_dir = BOT_REPO / "tools"
    if bot_py.exists():
        targets.append(str(bot_py.relative_to(BOT_REPO)))
    if env_file.exists():
        targets.append(str(env_file.relative_to(BOT_REPO)))
    if tools_dir.exists():
        targets.append(str(tools_dir.relative_to(BOT_REPO)))
    if not targets:
        raise RuntimeError("нет файлов для backup'а — пути отсутствуют")
    subprocess.run(
        ["tar", "-czf", str(snap), "-C", str(BOT_REPO), *targets],
        check=True, capture_output=True,
    )
    return snap


async def _edit_progress(msg, text):
    """Аккуратно обновляет сообщение; если edit fails — шлёт новое."""
    try:
        await msg.edit_text(text, parse_mode="HTML", disable_web_page_preview=True)
    except Exception:
        try:
            await msg.answer(text, parse_mode="HTML", disable_web_page_preview=True)
        except Exception:
            pass


async def _run_script(script_path):
    """Запуск .sh с timeout. Возвращает (rc, stdout, stderr)."""
    try:
        proc = await asyncio.create_subprocess_exec(
            "bash", str(script_path),
            cwd=str(DOCUMENTS_DIR),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    except Exception as e:
        return 1, "", f"не удалось запустить: {type(e).__name__}: {e}"

    try:
        stdout_b, stderr_b = await asyncio.wait_for(proc.communicate(), timeout=RUN_TIMEOUT)
    except asyncio.TimeoutError:
        proc.kill()
        try:
            await proc.communicate()
        except Exception:
            pass
        return 124, "", f"⏱ TIMEOUT после {RUN_TIMEOUT}s — процесс убит"

    return (proc.returncode or 0,
            stdout_b.decode(errors="replace"),
            stderr_b.decode(errors="replace"))


async def _handle_apply(message, bot, admin_ids):
    user_id = message.from_user.id if message.from_user else 0
    if user_id not in admin_ids:
        await message.answer("⛔ /apply доступен только админу")
        return

    args = (message.text or "").split(maxsplit=1)
    if len(args) < 2:
        await message.answer(
            "Использование: <code>/apply &lt;filename.sh&gt;</code>\n"
            "Файл должен лежать в <code>~/Documents/</code>",
            parse_mode="HTML",
        )
        return
    filename = args[1].strip()

    okv, err = _validate_name(filename)
    if not okv:
        await message.answer(f"❌ {err}")
        return

    script_path = DOCUMENTS_DIR / filename
    if not script_path.exists():
        await message.answer(f"❌ файл не найден: <code>{script_path}</code>", parse_mode="HTML")
        return
    size = script_path.stat().st_size
    if size == 0:
        await message.answer("❌ файл пустой")
        return
    if size > MAX_FILE_SIZE:
        await message.answer(
            f"❌ файл слишком большой: {size:,} байт "
            f"(лимит {MAX_FILE_SIZE:,}, override через APPLY_MAX_FILE_MB)"
        )
        return

    header = f"🔧 <b>/apply {filename}</b>"
    progress = await message.answer(f"{header}\n• Проверяю синтаксис...", parse_mode="HTML")

    # 1) bash -n
    syntax = subprocess.run(["bash", "-n", str(script_path)], capture_output=True, text=True)
    if syntax.returncode != 0:
        await _edit_progress(
            progress,
            f"{header}\n❌ Синтаксис некорректен (bash -n rc={syntax.returncode}):\n"
            f"<pre>{_tail(syntax.stderr, 600)}</pre>",
        )
        return

    # 2) shellcheck (errors only, non-blocking)
    shellcheck_note = ""
    if shutil.which("shellcheck"):
        sc = subprocess.run(
            ["shellcheck", "-S", "error", "-f", "tty", str(script_path)],
            capture_output=True, text=True,
        )
        if sc.returncode != 0 and sc.stdout.strip():
            shellcheck_note = f"\n⚠️ shellcheck (errors):\n<pre>{_tail(sc.stdout, 400)}</pre>"

    # 3) chmod +x
    try:
        script_path.chmod(0o755)
    except Exception as e:
        await _edit_progress(progress, f"{header}\n❌ chmod +x failed: {e}")
        return

    # 4) backup
    await _edit_progress(
        progress,
        f"{header}\n✅ Синтаксис OK{shellcheck_note}\n💾 Делаю backup...",
    )
    ts = datetime.now().strftime("%Y%m%dT%H%M%S")
    try:
        snap = _make_backup(ts)
    except Exception as e:
        await _edit_progress(progress, f"{header}\n❌ backup failed: {e}")
        return

    # 5) run
    await _edit_progress(
        progress,
        f"{header}\n✅ Синтаксис OK{shellcheck_note}\n"
        f"💾 Backup: <code>{snap.name}</code>\n"
        f"⚙️ Выполняю (timeout {RUN_TIMEOUT}s)...",
    )
    started = time.time()
    rc, stdout, stderr = await _run_script(script_path)
    elapsed = int(time.time() - started)

    if rc != 0:
        tail_block = stderr.strip() or stdout.strip() or "(пусто)"
        await _edit_progress(
            progress,
            f"{header}\n❌ FAILED rc={rc} ({elapsed}s)\n"
            f"<pre>{_tail(tail_block, 700)}</pre>\n"
            f"💾 Snapshot: <code>{snap.name}</code> — для отката",
        )
        return

    # 6) restart notice
    chat_id = message.chat.id
    notice = {
        "filename": filename,
        "rc": rc,
        "elapsed_sec": elapsed,
        "ts": ts,
        "chat_id": chat_id,
        "snap": snap.name,
        "stdout_tail": _tail(stdout, 400),
    }
    try:
        STARTUP_NOTICE_FILE.write_text(json.dumps(notice, ensure_ascii=False))
    except Exception:
        pass  # не фатально

    # 7) edit + detached restart
    await _edit_progress(
        progress,
        f"{header}\n✅ rc=0 ({elapsed}s)\n"
        f"💾 Snapshot: <code>{snap.name}</code>\n"
        f"📤 stdout tail:\n<pre>{_tail(stdout, 500)}</pre>\n"
        f"🔁 Рестартую <code>{SERVICE_NAME}</code>...",
    )

    # detach + 2s sleep — даём Telegram доставить edit до того как нас kill'нут
    subprocess.Popen(
        ["bash", "-c", f"sleep 2 && systemctl --user restart {SERVICE_NAME}"],
        start_new_session=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=True,
    )


def register_apply_handler(dp, bot, admin_ids):
    """Подключает /apply handler к Dispatcher'у.

    admin_ids: iterable of int — Telegram user_ids кому разрешён /apply.
    """
    admin_set = {int(x) for x in admin_ids if str(x).lstrip("-").isdigit()}

    @dp.message(Command("apply"))
    async def _apply(message):
        await _handle_apply(message, bot, admin_set)


def register_startup_notice(dp, bot):
    """Регистрирует on_startup хук, который шлёт админу «🟢 поднят»
    если /apply триггерил restart."""

    @dp.startup()
    async def _on_start():
        if not STARTUP_NOTICE_FILE.exists():
            return
        try:
            notice = json.loads(STARTUP_NOTICE_FILE.read_text())
            chat_id = notice.get("chat_id")
            if not chat_id:
                return
            filename = notice.get("filename", "?")
            rev = _git_rev(BOT_REPO)
            now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            await bot.send_message(
                chat_id,
                f"🟢 <b>Bot перезапущен после /apply</b>\n"
                f"• Файл: <code>{filename}</code>\n"
                f"• Git rev: <code>{rev}</code>\n"
                f"• Время: {now}",
                parse_mode="HTML",
            )
        except Exception as e:
            print(f"[apply_command] notify_startup failed: {e}")
        finally:
            try:
                STARTUP_NOTICE_FILE.unlink()
            except Exception:
                pass
