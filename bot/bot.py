"""Home AI Assistant Bot.

Telegram-front для домашнего AI-сервера Юры (Ryzen 5 3500 + RTX 4060 + Pop_OS).
Под капотом: aiogram 3 + Ollama (local LLM) + SQLite (state) + asyncio.Queue (rate limiting).

Архитектура:
1. Whitelist — middleware, отбраковывает не-allowlisted user_id
2. Async queue — один inference в моменте (одна GPU), новые запросы стоят в очереди с ETA
3. Router с double self-check — выбор модели (instruct / coder / vl) с верификацией
4. Conversation history — последние N сообщений per user в SQLite
5. Admin commands — /add, /remove, /list, /stats, /health
"""

import asyncio
import json
import logging
import os
import sys
import base64  # P4-mini: было внутри handler
import time
from datetime import datetime, timezone
from pathlib import Path

import aiosqlite
import httpx
from aiogram import Bot, Dispatcher, F, types
from aiogram.client.default import DefaultBotProperties
from aiogram.enums import ParseMode
from aiogram.filters import Command, CommandStart
from aiogram.types import Message, ReactionTypeEmoji  # P4-mini: reactions
from dotenv import load_dotenv

# ============================================================
# Config (env)
# ============================================================
ROOT = Path(__file__).resolve().parent.parent  # ~/ai-assistant
load_dotenv(ROOT / ".env")

# P2: чтобы из bot.py можно было импортнуть пакет tools/ (~/ai-assistant/tools/)
# вне зависимости от cwd при запуске. Делаем ДО from-import.
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from tools.llm_loop import chat_with_tools  # noqa: E402  (после sys.path patch)

BOT_TOKEN = os.environ.get("BOT_TOKEN", "").strip()
ADMIN_IDS = {
    int(x) for x in os.environ.get("ADMIN_USER_IDS", "").split(",") if x.strip().isdigit()
}
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434").rstrip("/")
DB_PATH = Path(os.environ.get("DB_PATH", ROOT / "data" / "bot.db"))
LOG_PATH = Path(os.environ.get("LOG_PATH", ROOT / "logs" / "bot.log"))

# Модели — должны совпадать с теми, что Ollama скачал на P0
MODEL_INSTRUCT = os.environ.get("MODEL_INSTRUCT", "qwen2.5:7b-instruct-q4_K_M")
MODEL_CODER = os.environ.get("MODEL_CODER", "qwen2.5-coder:7b")
MODEL_VISION = os.environ.get("MODEL_VISION", "qwen2.5vl:7b")
MODEL_ROUTER = os.environ.get("MODEL_ROUTER", MODEL_INSTRUCT)  # для классификации intent

# Лимиты
HISTORY_LIMIT_MESSAGES = int(os.environ.get("HISTORY_LIMIT_MESSAGES", "20"))
RATE_LIMIT_PER_HOUR = int(os.environ.get("RATE_LIMIT_PER_HOUR", "30"))
QUEUE_MAX_SIZE = int(os.environ.get("QUEUE_MAX_SIZE", "100"))
LLM_TIMEOUT_SECONDS = int(os.environ.get("LLM_TIMEOUT_SECONDS", "300"))

# ============================================================
# Logging
# ============================================================
LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[logging.FileHandler(LOG_PATH), logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("home-ai-bot")


# ============================================================
# Database helpers
# ============================================================
async def db_init():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    if not DB_PATH.exists():
        # первичная инициализация — schema.sql лежит рядом
        schema_path = Path(__file__).parent / "schema.sql"
        if not schema_path.exists():
            log.error("schema.sql not found at %s", schema_path)
            sys.exit(1)
        async with aiosqlite.connect(DB_PATH) as db:
            await db.executescript(schema_path.read_text())
            await db.commit()
        log.info("SQLite initialized at %s", DB_PATH)


async def db_lifecycle(event: str, details: dict | None = None):
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            "INSERT INTO bot_lifecycle (event, details) VALUES (?, ?)",
            (event, json.dumps(details or {}, ensure_ascii=False)),
        )
        await db.commit()


async def db_is_allowed(user_id: int) -> bool:
    async with aiosqlite.connect(DB_PATH) as db:
        async with db.execute(
            "SELECT 1 FROM users WHERE user_id = ? LIMIT 1", (user_id,)
        ) as c:
            return (await c.fetchone()) is not None


async def db_is_admin(user_id: int) -> bool:
    if user_id in ADMIN_IDS:
        return True
    async with aiosqlite.connect(DB_PATH) as db:
        async with db.execute(
            "SELECT role FROM users WHERE user_id = ?", (user_id,)
        ) as c:
            row = await c.fetchone()
            return row is not None and row[0] == "admin"


async def db_add_user(
    user_id: int, username: str | None, display_name: str | None, role: str, added_by: int
):
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            """INSERT INTO users (user_id, username, display_name, role, added_by)
               VALUES (?, ?, ?, ?, ?)
               ON CONFLICT(user_id) DO UPDATE SET
                   username = excluded.username,
                   display_name = excluded.display_name,
                   role = excluded.role""",
            (user_id, username, display_name, role, added_by),
        )
        await db.commit()


async def db_remove_user(user_id: int) -> bool:
    async with aiosqlite.connect(DB_PATH) as db:
        cur = await db.execute("DELETE FROM users WHERE user_id = ?", (user_id,))
        await db.commit()
        return cur.rowcount > 0


async def db_list_users() -> list[tuple]:
    async with aiosqlite.connect(DB_PATH) as db:
        async with db.execute(
            "SELECT user_id, username, display_name, role, added_at, last_seen_at FROM users ORDER BY added_at"
        ) as c:
            return await c.fetchall()


async def db_history(user_id: int, limit: int = HISTORY_LIMIT_MESSAGES) -> list[dict]:
    async with aiosqlite.connect(DB_PATH) as db:
        async with db.execute(
            "SELECT role, content FROM messages WHERE user_id = ? ORDER BY ts DESC LIMIT ?",
            (user_id, limit),
        ) as c:
            rows = list(await c.fetchall())
        rows.reverse()
        return [{"role": r[0], "content": r[1]} for r in rows]


async def db_record_message(
    user_id: int,
    direction: str,
    role: str,
    content: str,
    model: str | None = None,
    tokens_in: int | None = None,
    tokens_out: int | None = None,
    duration_ms: int | None = None,
) -> int:
    async with aiosqlite.connect(DB_PATH) as db:
        cur = await db.execute(
            """INSERT INTO messages (user_id, direction, role, content, model, tokens_in, tokens_out, duration_ms)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (user_id, direction, role, content, model, tokens_in, tokens_out, duration_ms),
        )
        await db.commit()
        return cur.lastrowid or 0


async def db_record_route(
    user_id: int, message_id: int, first: str, second: str, final: str, intent: str
):
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            """INSERT INTO model_routes (user_id, message_id, first_choice, second_check, final_choice, intent_label)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (user_id, message_id, first, second, final, intent),
        )
        await db.commit()


async def db_touch_seen(user_id: int):
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            "UPDATE users SET last_seen_at = CURRENT_TIMESTAMP WHERE user_id = ?",
            (user_id,),
        )
        await db.commit()


async def db_incr_usage(user_id: int, tokens_in: int, tokens_out: int):
    bucket = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H")
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            """INSERT INTO usage_stats (user_id, bucket_hour, requests, tokens_in, tokens_out)
               VALUES (?, ?, 1, ?, ?)
               ON CONFLICT(user_id, bucket_hour) DO UPDATE SET
                   requests = requests + 1,
                   tokens_in = tokens_in + excluded.tokens_in,
                   tokens_out = tokens_out + excluded.tokens_out""",
            (user_id, bucket, tokens_in, tokens_out),
        )
        await db.commit()


async def db_usage_this_hour(user_id: int) -> int:
    bucket = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H")
    async with aiosqlite.connect(DB_PATH) as db:
        async with db.execute(
            "SELECT requests FROM usage_stats WHERE user_id = ? AND bucket_hour = ?",
            (user_id, bucket),
        ) as c:
            row = await c.fetchone()
            return row[0] if row else 0


# ============================================================
# P4-mini: reactions helper (не падает на ошибке)
# ============================================================
async def _react(msg: Message, emoji: str) -> None:
    try:
        await bot.set_message_reaction(
            chat_id=msg.chat.id,
            message_id=msg.message_id,
            reaction=[ReactionTypeEmoji(emoji=emoji)],
        )
    except Exception as e:
        log.debug("set_message_reaction(%s) failed: %s", emoji, e)


# ============================================================
# P4-mini: user_profiles (долгосрочная память per-user)
# ============================================================
async def db_get_profile(user_id: int) -> str:
    async with aiosqlite.connect(DB_PATH) as db:
        async with db.execute(
            "SELECT profile_md FROM user_profiles WHERE user_id = ?", (user_id,)
        ) as c:
            row = await c.fetchone()
            return row[0] if row else ""


async def db_set_profile(user_id: int, profile_md: str) -> None:
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            """INSERT INTO user_profiles (user_id, profile_md, updated_at)
               VALUES (?, ?, CURRENT_TIMESTAMP)
               ON CONFLICT(user_id) DO UPDATE SET
                   profile_md = excluded.profile_md,
                   updated_at = CURRENT_TIMESTAMP""",
            (user_id, profile_md),
        )
        await db.commit()


async def db_append_profile(user_id: int, addition: str) -> str:
    """Добавляет строку к существующему профилю. Возвращает новый профиль."""
    cur = await db_get_profile(user_id)
    new = (cur + "\n" + addition.strip()).strip() if cur else addition.strip()
    await db_set_profile(user_id, new)
    return new


async def db_clear_profile(user_id: int) -> None:
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute("DELETE FROM user_profiles WHERE user_id = ?", (user_id,))
        await db.commit()


async def db_clear_history(user_id: int) -> int:
    """Очищает messages + model_routes для одного user_id. Возвращает сколько messages удалено."""
    async with aiosqlite.connect(DB_PATH) as db:
        cur = await db.execute("DELETE FROM messages WHERE user_id = ?", (user_id,))
        deleted = cur.rowcount or 0
        await db.execute("DELETE FROM model_routes WHERE user_id = ?", (user_id,))
        await db.commit()
        return deleted


# ============================================================
# Ollama HTTP client
# ============================================================
async def ollama_chat(
    model: str,
    messages: list[dict],
    timeout: int = LLM_TIMEOUT_SECONDS,
    images: list[str] | None = None,
) -> tuple[str, dict]:
    """Вызывает Ollama /api/chat. Возвращает (response_text, metadata)."""
    payload = {
        "model": model,
        "messages": messages,
        "stream": False,
    }
    if images:
        # для vision-моделей последнее сообщение получает images поле
        if payload["messages"]:
            payload["messages"][-1]["images"] = images
    async with httpx.AsyncClient(timeout=timeout) as client:
        r = await client.post(f"{OLLAMA_URL}/api/chat", json=payload)
        r.raise_for_status()
        data = r.json()
    msg = data.get("message", {})
    return msg.get("content", ""), {
        "eval_count": data.get("eval_count"),
        "prompt_eval_count": data.get("prompt_eval_count"),
        "total_duration_ns": data.get("total_duration"),
    }


# ============================================================
# Router — double self-check на выбор модели
# ============================================================
ROUTER_PROMPT_FIRST = """Ты — классификатор намерений (intent classifier). Получаешь сообщение пользователя и определяешь, какая модель должна на него ответить.

Доступны 3 модели:
- "instruct" — общий чатер, для повседневных диалогов, вопросов, объяснений (default)
- "coder" — программистские задачи: написать/отладить код, объяснить snippet, refactor, регулярки, shell-команды
- "vl" — vision: если в сообщении есть прикреплённое изображение

Ответь ТОЛЬКО одним словом: instruct, coder или vl. Без объяснений.

Сообщение пользователя:
---
{user_text}
---"""

ROUTER_PROMPT_VERIFY = """Ты — верификатор выбора модели. Первая классификация дала ответ: "{first_choice}".

Перепроверь, корректен ли этот выбор для сообщения ниже. Если согласен — ответь "same". Если не согласен — ответь одним словом: instruct, coder или vl (новый правильный выбор). Без объяснений.

Доступны:
- "instruct" — общий чатер
- "coder" — программирование
- "vl" — есть изображение

Сообщение пользователя:
---
{user_text}
---

Первая классификация: {first_choice}
Твой вердикт:"""


async def route_with_double_check(
    user_text: str, has_image: bool
) -> tuple[str, str, str, str]:
    """Возвращает (first, second, final, intent_label)."""
    # Если изображение прикреплено — короткий путь, vl без верификации
    if has_image:
        return "vl", "vl", "vl", "image"

    # Первая классификация
    first_msgs = [{"role": "user", "content": ROUTER_PROMPT_FIRST.format(user_text=user_text)}]
    try:
        first_raw, _ = await ollama_chat(MODEL_ROUTER, first_msgs, timeout=10)  # P4-mini
        first = first_raw.strip().lower().split()[0] if first_raw.strip() else "instruct"
    except Exception as e:
        log.warning("router first-pass failed: %s — defaulting to instruct", e)
        first = "instruct"

    if first not in {"instruct", "coder", "vl"}:
        first = "instruct"

    # Верификация
    verify_msgs = [
        {
            "role": "user",
            "content": ROUTER_PROMPT_VERIFY.format(
                user_text=user_text, first_choice=first
            ),
        }
    ]
    try:
        verify_raw, _ = await ollama_chat(MODEL_ROUTER, verify_msgs, timeout=10)  # P4-mini
        verify = verify_raw.strip().lower().split()[0] if verify_raw.strip() else "same"
    except Exception as e:
        log.warning("router verify-pass failed: %s — using first choice", e)
        verify = "same"

    if verify == "same" or verify not in {"instruct", "coder", "vl"}:
        final = first
        second_check = "same"
    else:
        final = verify
        second_check = "changed"

    # Не возвращаем vl если изображения реально нет
    if final == "vl" and not has_image:
        final = "instruct"

    intent = {"instruct": "общий", "coder": "код", "vl": "картинка"}[final]
    return first, second_check, final, intent


def model_id_by_choice(choice: str) -> str:
    return {
        "instruct": MODEL_INSTRUCT,
        "coder": MODEL_CODER,
        "vl": MODEL_VISION,
    }.get(choice, MODEL_INSTRUCT)


# ============================================================
# Queue (один inference в моменте)
# ============================================================
inference_queue: asyncio.Queue = asyncio.Queue(maxsize=QUEUE_MAX_SIZE)
inference_active = asyncio.Lock()


async def inference_worker():
    """Один worker, обрабатывает inference последовательно."""
    while True:
        task = await inference_queue.get()
        async with inference_active:
            try:
                await task()
            except Exception as e:
                log.exception("inference task failed: %s", e)
        inference_queue.task_done()


# ============================================================
# Bot
# ============================================================
if not BOT_TOKEN:
    log.error("BOT_TOKEN не задан в .env — запуск невозможен")
    sys.exit(1)

bot = Bot(token=BOT_TOKEN, default=DefaultBotProperties(parse_mode=ParseMode.HTML))
dp = Dispatcher()


# ============================================================
# Middleware: whitelist + rate limit
# ============================================================
@dp.message.middleware()
async def access_middleware(handler, event: Message, data):
    user_id = event.from_user.id if event.from_user else 0

    # Bootstrap: первый Admin из .env может ВСЕГДА (даже если ещё нет в DB)
    if user_id in ADMIN_IDS:
        # автоматически добавим в DB как admin при первом контакте
        async with aiosqlite.connect(DB_PATH) as db:
            async with db.execute(
                "SELECT 1 FROM users WHERE user_id = ?", (user_id,)
            ) as c:
                exists = await c.fetchone() is not None
        if not exists:
            await db_add_user(
                user_id,
                event.from_user.username,
                event.from_user.full_name,
                "admin",
                user_id,
            )
            log.info("auto-added admin user_id=%s", user_id)
        await db_touch_seen(user_id)
        return await handler(event, data)

    # Whitelist check
    if not await db_is_allowed(user_id):
        log.info("rejected user_id=%s (not in whitelist)", user_id)
        await event.answer(
            "Извини, у тебя нет доступа к этому боту. Если считаешь что должен — напиши админу."
        )
        return

    # Rate limit
    requests_this_hour = await db_usage_this_hour(user_id)
    if requests_this_hour >= RATE_LIMIT_PER_HOUR:
        await event.answer(
            f"⏳ Достигнут лимит {RATE_LIMIT_PER_HOUR} запросов в час. "
            "Попробуй через час."
        )
        return

    await db_touch_seen(user_id)
    return await handler(event, data)


# ============================================================
# Handlers
# ============================================================
@dp.message(CommandStart())
async def start_handler(msg: Message):
    is_admin = await db_is_admin(msg.from_user.id)
    role_label = "админ" if is_admin else "пользователь"
    await msg.answer(
        f"Привет, {msg.from_user.first_name}! Я — твой домашний AI-помощник.\n\n"
        f"Твоя роль: <b>{role_label}</b>\n\n"
        "Просто напиши мне что-нибудь, и я отвечу. "
        "Если приложишь картинку — могу её описать.\n\n"
        "Полезные команды:\n"
        "• /health — состояние бота\n"
        "• /stats — твоя статистика\n"
        "• /profile — твой долгосрочный профиль\n"
        "• /reset — очистить мою историю переписки\n"
        + (
            "\nАдмин-команды:\n"
            "• /add &lt;user_id&gt; [@username] [name] — добавить пользователя\n"
            "• /remove &lt;user_id&gt; — убрать пользователя\n"
            "• /list — список пользователей\n"
            if is_admin
            else ""
        )
    )


@dp.message(Command("health"))
async def health_handler(msg: Message):
    queue_size = inference_queue.qsize()
    is_busy = inference_active.locked()
    async with aiosqlite.connect(DB_PATH) as db:
        async with db.execute("SELECT COUNT(*) FROM users") as c:
            users_count = (await c.fetchone())[0]
        async with db.execute("SELECT COUNT(*) FROM messages") as c:
            messages_count = (await c.fetchone())[0]
    # Ollama health
    ollama_ok = False
    try:
        async with httpx.AsyncClient(timeout=3) as client:
            r = await client.get(f"{OLLAMA_URL}/api/tags")
            ollama_ok = r.status_code == 200
    except Exception:
        ollama_ok = False
    await msg.answer(
        "🩺 <b>Bot health</b>\n\n"
        f"• Ollama: {'✅ online' if ollama_ok else '❌ offline'} ({OLLAMA_URL})\n"
        f"• Inference busy: {'🔄 yes' if is_busy else '⏸ no'}\n"
        f"• Queue size: {queue_size}\n"
        f"• Users in whitelist: {users_count}\n"
        f"• Total messages logged: {messages_count}\n"
        f"• DB: <code>{DB_PATH}</code>"
    )


@dp.message(Command("stats"))
async def stats_handler(msg: Message):
    user_id = msg.from_user.id
    requests = await db_usage_this_hour(user_id)
    async with aiosqlite.connect(DB_PATH) as db:
        async with db.execute(
            "SELECT COUNT(*) FROM messages WHERE user_id = ?", (user_id,)
        ) as c:
            total = (await c.fetchone())[0]
    await msg.answer(
        "📊 <b>Твоя статистика</b>\n\n"
        f"• Запросов в текущем часе: {requests} / {RATE_LIMIT_PER_HOUR}\n"
        f"• Всего сообщений: {total}"
    )


@dp.message(Command("add"))
async def add_handler(msg: Message):
    if not await db_is_admin(msg.from_user.id):
        return await msg.answer("Эта команда только для админа.")
    args = msg.text.split(maxsplit=3) if msg.text else []
    if len(args) < 2 or not args[1].isdigit():
        return await msg.answer(
            "Использование: <code>/add &lt;user_id&gt; [@username] [name]</code>\n"
            "Узнать user_id: попроси юзера написать боту @userinfobot"
        )
    new_uid = int(args[1])
    username = args[2].lstrip("@") if len(args) >= 3 else None
    name = args[3] if len(args) >= 4 else None
    await db_add_user(new_uid, username, name, "user", msg.from_user.id)
    await msg.answer(
        f"✅ Добавил: <code>{new_uid}</code>"
        + (f" (@{username})" if username else "")
        + (f" — {name}" if name else "")
    )


@dp.message(Command("remove"))
async def remove_handler(msg: Message):
    if not await db_is_admin(msg.from_user.id):
        return await msg.answer("Эта команда только для админа.")
    args = msg.text.split(maxsplit=1) if msg.text else []
    if len(args) < 2 or not args[1].isdigit():
        return await msg.answer("Использование: <code>/remove &lt;user_id&gt;</code>")
    target = int(args[1])
    if target == msg.from_user.id:
        return await msg.answer("Себя удалить нельзя.")
    ok = await db_remove_user(target)
    await msg.answer("✅ Удалил." if ok else "❌ Не нашёл такого user_id в whitelist.")


@dp.message(Command("list"))
async def list_handler(msg: Message):
    if not await db_is_admin(msg.from_user.id):
        return await msg.answer("Эта команда только для админа.")
    users = await db_list_users()
    if not users:
        return await msg.answer("Whitelist пустой.")
    lines = ["<b>Whitelist:</b>"]
    for uid, username, name, role, added, seen in users:
        label = name or (f"@{username}" if username else f"id={uid}")
        lines.append(f"• <code>{uid}</code> {label} ({role})")
    await msg.answer("\n".join(lines))


# ============================================================
# P4-mini: команды /reset, /profile, /profile_set, /profile_add, /profile_clear
# ============================================================
@dp.message(Command("reset"))
async def reset_handler(msg: Message):
    deleted = await db_clear_history(msg.from_user.id)
    await msg.answer(f"🧹 История очищена ({deleted} сообщений удалено). "
                     "Профиль не тронут — он работает long-term.")


@dp.message(Command("profile"))
async def profile_handler(msg: Message):
    p = await db_get_profile(msg.from_user.id)
    if p:
        await msg.answer(f"🧠 <b>Твой профиль:</b>\n<pre>{p}</pre>\n\n"
                         "Команды: /profile_set, /profile_add, /profile_clear")
    else:
        await msg.answer("🧠 Профиль пустой.\n\n"
                         "Заполни через:\n"
                         "• /profile_set &lt;текст&gt; — заменить весь профиль\n"
                         "• /profile_add &lt;текст&gt; — добавить строчку\n\n"
                         "Что писать: язык общения, твои предпочтения по стилю ответов, "
                         "контекст работы, важные особенности. Профиль вкладывается в каждый запрос.")


@dp.message(Command("profile_set"))
async def profile_set_handler(msg: Message):
    parts = (msg.text or "").split(maxsplit=1)
    if len(parts) < 2 or not parts[1].strip():
        return await msg.answer("Использование: <code>/profile_set текст профиля</code>")
    await db_set_profile(msg.from_user.id, parts[1].strip())
    await msg.answer("✅ Профиль обновлён. Проверь через /profile")


@dp.message(Command("profile_add"))
async def profile_add_handler(msg: Message):
    parts = (msg.text or "").split(maxsplit=1)
    if len(parts) < 2 or not parts[1].strip():
        return await msg.answer("Использование: <code>/profile_add строка</code>")
    new = await db_append_profile(msg.from_user.id, parts[1].strip())
    await msg.answer(f"✅ Добавил. Текущий профиль:\n<pre>{new}</pre>")


@dp.message(Command("profile_clear"))
async def profile_clear_handler(msg: Message):
    await db_clear_profile(msg.from_user.id)
    await msg.answer("🧹 Профиль очищен.")


# ============================================================
# Main message handler
# ============================================================
@dp.message(F.text | F.photo | F.document)
async def chat_handler(msg: Message):
    user_id = msg.from_user.id
    user_text = (msg.text or msg.caption or "").strip()
    has_image = bool(msg.photo)

    if not user_text and not has_image:
        return  # ignore stickers / voice / etc

    # P4-mini: реакция «увидел» сразу
    await _react(msg, "👀")

    # Помещаем в очередь — обрабатываем последовательно
    queue_pos = inference_queue.qsize()
    if queue_pos > 0:
        await msg.answer(
            f"⏳ В очереди: {queue_pos + 1} запросов перед твоим. "
            f"~{(queue_pos + 1) * 15} сек ожидания."
        )

    async def process():
        nonlocal user_text  # P3 fix: assignment в document handler ниже делает user_text локальной без этого
        start_ts = time.monotonic()
        # P3: document handling — если приехал PDF/DOCX, скачиваем в sandbox/uploads/
        # и подменяем user_text на инструкцию модели read_pdf/read_docx.
        if msg.document and msg.document.mime_type in (
            "application/pdf",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        ):
            from pathlib import Path as _Path
            sandbox = _Path(os.environ.get("BOT_SANDBOX", str(_Path.home() / "bot-workspace")))
            uploads = sandbox / "uploads"
            uploads.mkdir(parents=True, exist_ok=True)
            fname = msg.document.file_name or f"upload-{int(time.time())}"
            safe_name = "".join(c if c.isalnum() or c in "._-" else "_" for c in fname)
            local_path = uploads / safe_name
            try:
                tg_file = await bot.get_file(msg.document.file_id)
                buf = await bot.download_file(tg_file.file_path)
                local_path.write_bytes(buf.read())
                log.info("document saved: %s (%s bytes)", local_path, local_path.stat().st_size)
                hint = f"Юзер прислал документ uploads/{safe_name}. "
                if msg.document.mime_type == "application/pdf":
                    hint += "Используй read_pdf чтобы прочитать. "
                else:
                    hint += "Используй read_docx чтобы прочитать. "
                if user_text:
                    user_text = hint + "Запрос: " + user_text
                else:
                    user_text = hint + "Сделай краткое summary."
            except Exception as e:
                log.warning("document download failed: %s", e)
                await msg.answer(f"Не смог скачать документ: {e}")
                return

        # Скачиваем картинку (base64) если есть
        image_b64 = None
        MAX_IMAGE_BYTES = 5 * 1024 * 1024  # P4-mini: 5MB hard limit чтобы не OOM на 16GB RAM
        if has_image:
            try:
                photo = msg.photo[-1]  # самый большой size
                file = await bot.get_file(photo.file_id)
                if file.file_size and file.file_size > MAX_IMAGE_BYTES:
                    await msg.answer(f"Картинка больше {MAX_IMAGE_BYTES // 1024 // 1024} MB — слишком тяжёлая для vision-модели. Сожми и пришли заново.")
                    return
                buf = await bot.download_file(file.file_path)
                raw = buf.read()
                if len(raw) > MAX_IMAGE_BYTES:
                    await msg.answer("Картинка превысила лимит после download — пропускаю.")
                    return
                image_b64 = base64.b64encode(raw).decode()
            except Exception as e:
                log.warning("photo download failed: %s", e)

        # 1) Сохраняем входящее
        in_msg_id = await db_record_message(
            user_id, "in", "user", user_text or "[image]"
        )

        # 2) Router с double-check
        first, second_check, final_choice, intent = await route_with_double_check(
            user_text, has_image
        )
        await db_record_route(user_id, in_msg_id, first, second_check, final_choice, intent)

        chosen_model = model_id_by_choice(final_choice)
        log.info(
            "user=%s intent=%s route=%s→%s model=%s",
            user_id,
            intent,
            first,
            final_choice,
            chosen_model,
        )

        # 3) Собираем conversation history + system prompt
        history = await db_history(user_id)
        user_profile = await db_get_profile(user_id)  # P4-mini
        system = {
            "role": "system",
            "content": (
                "Ты — дружелюбный полезный домашний AI-помощник.\n"
                "ВАЖНЫЕ ПРАВИЛА ЯЗЫКА (обязательно):\n"
                "1. Всегда отвечай ИСКЛЮЧИТЕЛЬНО на русском языке. "
                "Ни одного слова, иероглифа или символа на других языках. "
                "Не вставляй китайский, английский, корейский или любой иной язык — даже в одно слово.\n"
                "2. Используй только стандартные русские буквы и пунктуацию. "
                "Никаких надстрочных или диакритических знаков (типа á, é, ñ).\n"
                "3. Если хочешь использовать иностранный термин — пиши его кириллицей или избегай.\n\n"
                "ИНСТРУМЕНТЫ (доступны на ветке instruct):\n"
                "- web_search(query, max_results) — поиск в интернете для свежих фактов, новостей, цен, курсов валют.\n"
                "- read_file(path), write_file(path, content), list_dir(path), search_files(pattern, path) — "
                "работа с файлами в личной песочнице пользователя (BOT_SANDBOX).\n"
                "Вызывай инструменты сам, когда они уместны. Передавай аргументы строго по JSON-схеме. "
                "Не выдумывай содержимое веб-страниц или файлов — если не вызвал tool, не утверждай факт.\n\n"
                "ПО СОДЕРЖАНИЮ:\n"
                "- Отвечай кратко и по делу.\n"
                "- Если не знаешь и инструменты не помогли — честно скажи «не знаю», не выдумывай.\n\n"
                + ("ПЕРСОНАЛЬНЫЙ ПРОФИЛЬ ЮЗЕРА (вкладывается всегда, учитывай при ответе):\n" + user_profile if user_profile else "")
            ),
        }
        messages_for_llm = [system] + history + [{"role": "user", "content": user_text}]

        # 4) Вызываем модель
        # P2: для ветки `instruct` идём через tool-loop (web_search + file ops).
        # Для `coder` и `vl` — прямой ollama_chat без инструментов (там они не нужны
        # и vision-модели Hermes-tool format обычно не понимают).
        try:
            if final_choice == "instruct" and not image_b64:
                # P2: используем TOOLS_MODEL из .env (специально для tool calling — qwen2.5),
                # а не chosen_model (=MODEL_INSTRUCT, обычно gemma4 которая Hermes tool format не умеет).
                tools_model = os.environ.get("TOOLS_MODEL") or chosen_model
                response_text, _ = await chat_with_tools(
                    user_text,
                    history,
                    model=tools_model,
                    ollama_url=OLLAMA_URL,
                    system_prompt=system["content"],
                )
                meta = {}
            else:
                response_text, meta = await ollama_chat(
                    chosen_model,
                    messages_for_llm,
                    images=[image_b64] if image_b64 else None,
                )
        except httpx.TimeoutException:
            await msg.answer("⏱ Ollama не ответила в течение тайм-аута. Попробуй ещё раз.")
            await _react(msg, "😢")
            return
        except Exception as e:
            log.exception("ollama call failed: %s", e)
            await msg.answer(f"❌ Ошибка модели: {e}")
            await _react(msg, "😢")
            return

        duration_ms = int((time.monotonic() - start_ts) * 1000)
        tokens_in = meta.get("prompt_eval_count") or 0
        tokens_out = meta.get("eval_count") or 0

        # 5) Отправляем ответ
        if response_text.strip():
            await msg.answer(response_text)
            await _react(msg, "🎉")  # P4-mini: успешный ответ
        else:
            await msg.answer("(пустой ответ от модели)")
            await _react(msg, "😢")

        # P3: document handling — если модель создала docx в sandbox/output/,
        # отправляем файл юзеру.
        try:
            from pathlib import Path as _Path
            from aiogram.types import FSInputFile as _FSInputFile
            sandbox = _Path(os.environ.get("BOT_SANDBOX", str(_Path.home() / "bot-workspace")))
            output_dir = sandbox / "output"
            if output_dir.exists():
                for docx_file in output_dir.glob("*.docx"):
                    # Отправляем только файлы созданные в текущем запросе (последние 60 сек)
                    if time.time() - docx_file.stat().st_mtime < 60:
                        try:
                            await msg.answer_document(_FSInputFile(str(docx_file)))
                            log.info("sent docx to user: %s", docx_file)
                        except Exception as e:
                            log.warning("send docx failed: %s", e)
                # P3b: image auto-send — сгенерированные PNG из ComfyUI
                for png_file in output_dir.glob("*.png"):
                    if time.time() - png_file.stat().st_mtime < 60:
                        try:
                            await msg.answer_photo(_FSInputFile(str(png_file)))
                            log.info("sent png to user: %s", png_file)
                        except Exception as e:
                            log.warning("send png failed: %s", e)
        except Exception as e:
            log.warning("docx auto-send check failed: %s", e)

        # 6) Сохраняем outgoing + статистику
        await db_record_message(
            user_id,
            "out",
            "assistant",
            response_text,
            model=chosen_model,
            tokens_in=tokens_in,
            tokens_out=tokens_out,
            duration_ms=duration_ms,
        )
        await db_incr_usage(user_id, tokens_in, tokens_out)

    await inference_queue.put(process)


# ============================================================
# main
# ============================================================
async def main():
    await db_init()
    await db_lifecycle("start", {"pid": os.getpid()})
    log.info("Bot starting. Admins: %s. Ollama: %s", ADMIN_IDS, OLLAMA_URL)

    # Запускаем worker'а
    worker = asyncio.create_task(inference_worker())

    try:
        await dp.start_polling(bot, allowed_updates=dp.resolve_used_update_types())
    finally:
        worker.cancel()
        await db_lifecycle("stop")
        log.info("Bot stopped.")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (KeyboardInterrupt, SystemExit):
        pass
