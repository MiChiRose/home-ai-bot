"""
Admin broadcast — рассылка одного сообщения всем allowlisted user'ам.

Поток:
  1. Админ пишет боту /broadcast (или /announce)
     → бот: "Что отправить? Жду текст следующим сообщением. /cancel — отмена."
     → флаг pending для admin user_id, TTL 5 минут.

  2. Следующее текстовое сообщение от того же админа (НЕ команда):
     → бот: "Превью: <текст>. Получателей: N. Подтверди /confirm или /cancel."

  3. /confirm → рассылка всем allowlisted (исключая самого админа); счётчик
     успехов/фейлов в финальном отчёте.
     /cancel в любой момент → reset.

Регистрируется через register_broadcast(dp, bot, list_recipients, is_admin).

⚠️ КРИТИЧНО (исправлено 2026-05-17 после msg 17373):
Раньше catcher был `@dp.message()` БЕЗ фильтра, и он перехватывал ВСЕ сообщения
(даже если внутри возвращал None для не-админов / не-pending). В aiogram 3.x
это поглощает event, и chat_handler НЕ срабатывает. Бот молча "читал" сообщения
без ответа. Сейчас catcher повешен на custom Filter, который матчит ТОЛЬКО когда
реально нужен — admin + pending broadcast + не команда. Всё остальное идёт дальше.
"""

from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass
from typing import Awaitable, Callable

from aiogram import Bot, Dispatcher
from aiogram.filters import Command, Filter
from aiogram.types import Message


_PENDING_TTL_SEC = 300  # 5 минут на сбор текста и подтверждение


@dataclass
class _Pending:
    stage: str  # "awaiting_text" | "awaiting_confirm"
    text: str | None
    expires_at: float


_PENDING: dict[int, _Pending] = {}


def _purge_expired() -> None:
    now = time.time()
    for uid in list(_PENDING):
        if _PENDING[uid].expires_at <= now:
            del _PENDING[uid]


def register_broadcast(
    dp: Dispatcher,
    bot: Bot,
    list_recipients: Callable[[], Awaitable[list[int]]],
    is_admin: Callable[[int], Awaitable[bool]],
) -> None:
    """Register /broadcast + /confirm + /cancel + intermediate-text handler.

    Args:
        dp: aiogram Dispatcher.
        bot: aiogram Bot instance — used to send messages to recipients.
        list_recipients: async callable returning list of allowlisted user_ids.
        is_admin: async callable(user_id) -> bool.
    """

    # ─── Custom filter — narrow matcher to admin+pending+not-a-command ──────
    # Без этого `@dp.message()` поглощает ВСЕ сообщения и chat_handler не срабатывает.
    class _AdminAwaitingBroadcast(Filter):
        async def __call__(self, message: Message) -> bool:
            if not message.from_user:
                return False
            uid = message.from_user.id
            _purge_expired()
            p = _PENDING.get(uid)
            if not p or p.stage != "awaiting_text":
                return False
            if not message.text or message.text.startswith("/"):
                return False
            return await is_admin(uid)

    @dp.message(Command("broadcast", "announce"))
    async def cmd_broadcast(message: Message) -> None:
        user_id = message.from_user.id if message.from_user else 0
        if not await is_admin(user_id):
            return  # silent ignore — не палим существование команды
        _purge_expired()
        _PENDING[user_id] = _Pending(
            stage="awaiting_text",
            text=None,
            expires_at=time.time() + _PENDING_TTL_SEC,
        )
        await message.answer(
            "📣 Что отправить allowlist'у? Напиши текст следующим сообщением.\n"
            "Отмена: <code>/cancel</code>. TTL: 5 минут."
        )

    @dp.message(Command("cancel"))
    async def cmd_cancel(message: Message) -> None:
        user_id = message.from_user.id if message.from_user else 0
        if not await is_admin(user_id):
            return
        if _PENDING.pop(user_id, None):
            await message.answer("✅ Pending broadcast отменён.")
        else:
            await message.answer("Нет pending broadcast'а.")

    @dp.message(Command("confirm"))
    async def cmd_confirm(message: Message) -> None:
        user_id = message.from_user.id if message.from_user else 0
        if not await is_admin(user_id):
            return
        _purge_expired()
        p = _PENDING.get(user_id)
        if not p or p.stage != "awaiting_confirm" or not p.text:
            await message.answer("Нет broadcast'а для подтверждения. Начни с <code>/broadcast</code>.")
            return

        text = p.text
        del _PENDING[user_id]

        recipients = await list_recipients()
        recipients = [uid for uid in recipients if uid != user_id]

        await message.answer(f"📤 Рассылаю {len(recipients)} получателям…")

        ok = 0
        fail = 0
        fail_samples: list[str] = []

        async def _send_one(uid: int) -> None:
            nonlocal ok, fail
            try:
                await bot.send_message(uid, text)
                ok += 1
            except Exception as e:
                fail += 1
                if len(fail_samples) < 5:
                    fail_samples.append(f"{uid}: {e}")

        sem = asyncio.Semaphore(10)

        async def _wrapped(uid: int) -> None:
            async with sem:
                await _send_one(uid)

        await asyncio.gather(*(_wrapped(uid) for uid in recipients))

        report = (
            f"✅ Рассылка завершена.\n"
            f"Доставлено: <b>{ok}</b>\n"
            f"Ошибок: <b>{fail}</b>"
        )
        if fail_samples:
            report += "\n\nПервые ошибки:\n<pre>" + "\n".join(fail_samples) + "</pre>"
        await message.answer(report)

    # Перехватываем текст ТОЛЬКО когда:
    #  - отправитель админ
    #  - есть pending broadcast в stage="awaiting_text"
    #  - сообщение НЕ команда (не начинается с `/`)
    # Все остальные сообщения проходят мимо этого handler'а к chat_handler.
    @dp.message(_AdminAwaitingBroadcast())
    async def _capture_broadcast_text(message: Message) -> None:
        user_id = message.from_user.id  # filter гарантирует что not None
        p = _PENDING[user_id]
        p.text = message.text
        p.stage = "awaiting_confirm"
        p.expires_at = time.time() + _PENDING_TTL_SEC

        recipients = await list_recipients()
        n = len([uid for uid in recipients if uid != user_id])
        preview = message.text if len(message.text) <= 800 else message.text[:800] + "…"
        await message.answer(
            f"📋 Превью:\n\n<pre>{preview}</pre>\n\n"
            f"Получателей: <b>{n}</b> (себя не считаем).\n\n"
            f"Подтверди: <code>/confirm</code>\n"
            f"Отмена: <code>/cancel</code>"
        )
