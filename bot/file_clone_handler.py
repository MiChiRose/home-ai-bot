"""
Admin file-clone commands — стянуть файл из bot project в DM админа.

Команды:
    /cloneBrains             — алиас для /cloneFile bot.py (восстановлен после v4).
    /cloneFile <rel-path>    — отправить любой файл из BOT_REPO_ROOT (~/ai-assistant/)
                                с защитой от path traversal (resolve + commonpath).

Использование:
    /cloneFile bot.py
    /cloneFile tools/llm_loop.py
    /cloneFile schema.sql
    /cloneFile ../.env                  # отклонено — за пределами REPO_ROOT
    /cloneFile /etc/passwd              # отклонено — абсолютный путь
    /cloneFile ../../../etc/passwd      # отклонено — path traversal

Регистрируется через register_file_clone(dp, repo_root, bot_self_path, admin_id).
Hard limit 45 MB на файл (Telegram bot send_document limit = 50 MB).
"""

from __future__ import annotations

import os
from pathlib import Path

from aiogram import Dispatcher
from aiogram.filters import Command
from aiogram.types import FSInputFile, Message


_MAX_FILE_SIZE = 45 * 1024 * 1024  # 45 MB safety margin under Telegram's 50 MB


def _safe_resolve(repo_root: Path, rel_path: str) -> Path | None:
    """Resolve `rel_path` против `repo_root`. Возвращает None если выходит за корень."""
    rel_path = rel_path.strip()
    if not rel_path:
        return None
    candidate = Path(rel_path)
    if candidate.is_absolute():
        return None
    full = (repo_root / candidate).resolve()
    try:
        full.relative_to(repo_root.resolve())
    except ValueError:
        return None
    return full


def register_file_clone(
    dp: Dispatcher,
    repo_root: Path,
    bot_self_path: Path,
    admin_id: int,
) -> None:
    """Register /cloneBrains + /cloneFile admin commands.

    Args:
        dp: aiogram Dispatcher.
        repo_root: bot repo root (e.g. `~/ai-assistant`). All /cloneFile paths are resolved against this.
        bot_self_path: absolute path to bot.py (for /cloneBrains alias).
        admin_id: Telegram user_id of the only allowed caller.
    """

    @dp.message(Command("cloneBrains"))
    async def cmd_clone_brains(message: Message) -> None:
        if message.from_user is None or message.from_user.id != admin_id:
            return  # silent — не палим существование команды
        path = Path(bot_self_path).resolve()
        if not path.exists():
            await message.answer(f"❌ bot.py не найден: {path}")
            return
        size = path.stat().st_size
        await message.answer_document(
            FSInputFile(path),
            caption=f"📂 {path.name} ({size} байт)",
        )

    @dp.message(Command("cloneFile"))
    async def cmd_clone_file(message: Message) -> None:
        if message.from_user is None or message.from_user.id != admin_id:
            return
        text = (message.text or "").strip()
        # `/cloneFile <path>` — path может содержать пробелы → берём всё после первого пробела
        parts = text.split(maxsplit=1)
        if len(parts) < 2 or not parts[1].strip():
            await message.answer(
                "Использование: <code>/cloneFile &lt;relative-path&gt;</code>\n\n"
                "Примеры:\n"
                "• <code>/cloneFile bot.py</code>\n"
                "• <code>/cloneFile tools/llm_loop.py</code>\n"
                "• <code>/cloneFile schema.sql</code>\n\n"
                "Путь резолвится относительно корня репо. Абсолютные пути и `..` за корень отклоняются."
            )
            return

        rel = parts[1].strip()
        full = _safe_resolve(Path(repo_root), rel)
        if full is None:
            await message.answer(
                f"⛔ Путь отклонён (абсолютный, traversal, или за пределами {repo_root}): "
                f"<code>{rel}</code>"
            )
            return
        if not full.exists():
            await message.answer(f"❌ Файл не существует: <code>{full}</code>")
            return
        if not full.is_file():
            await message.answer(f"❌ Не файл (директория или symlink-к-директории): <code>{full}</code>")
            return
        size = full.stat().st_size
        if size > _MAX_FILE_SIZE:
            mb = size / 1024 / 1024
            await message.answer(
                f"❌ Файл слишком большой: {mb:.1f} MB (лимит {_MAX_FILE_SIZE // 1024 // 1024} MB)"
            )
            return

        try:
            rel_for_caption = full.relative_to(Path(repo_root).resolve())
        except ValueError:
            rel_for_caption = full.name
        await message.answer_document(
            FSInputFile(full),
            caption=f"📂 {rel_for_caption} ({size} байт)",
        )
