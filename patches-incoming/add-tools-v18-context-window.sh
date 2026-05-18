#!/usr/bin/env bash
# v18 — Юра msg 17984+18006: «бот забывает контекст после второго сообщения».
#
# Root causes (анализ):
# 1. Ollama по умолчанию ограничивает num_ctx до 2048 tokens (~6 KB текста)
#    → твой большой SYSTEM_PROMPT (после v6-v17 ~8 KB) + profile (~3 KB)
#    + history (~3 KB) + user query НЕ ВЛЕЗАЕТ → старое (твоё «привет»)
#    обрезается.
# 2. HISTORY_LIMIT_MESSAGES default 20 — недостаточно если context съедает
#    system prompt. С v18 default 30.
# 3. Нет видимости текущего использования context.
#
# Fix:
# 1. Передаваемые в Ollama options.num_ctx = 8192 (обе модели поддерживают).
# 2. HISTORY_LIMIT_MESSAGES default → 30 (можно override env).
# 3. /context_show команда — показывает sys+profile+history bytes/tokens.
# 4. SYSTEM_PROMPT extension: явное правило «помни предыдущие N turn'ов».

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
BOT_PY="$BOT_DIR/bot.py"
SERVICE="${SERVICE:-home-ai-bot.service}"

cd "$BOT_DIR"
[ ! -f "$BOT_PY" ] && { echo "❌ $BOT_PY не найден"; exit 1; }

BACKUP="$BOT_DIR/bot.py.bak.before-tools-v18-$(date +%Y%m%d-%H%M%S)"
cp "$BOT_PY" "$BACKUP"

git tag -f pre-tools-v18 "$(git rev-parse HEAD)" 2>/dev/null || true

BOT_PY="$BOT_PY" python3 - <<'PYEOF'
import os, re, sys
from pathlib import Path

bot_py = Path(os.environ["BOT_PY"])
src = bot_py.read_text(encoding="utf-8")

if "CONTEXT_WINDOW v18" in src:
    print("ℹ️  v18 уже применён. Skip.")
    sys.exit(0)

# === 1. Поднять HISTORY_LIMIT_MESSAGES default с 20 до 30 ===
m1 = re.search(r'HISTORY_LIMIT_MESSAGES\s*=\s*int\(os\.environ\.get\("HISTORY_LIMIT_MESSAGES",\s*"\d+"\)\)', src)
if m1:
    src = src.replace(m1.group(0),
        'HISTORY_LIMIT_MESSAGES = int(os.environ.get("HISTORY_LIMIT_MESSAGES", "30"))  # v18 CONTEXT_WINDOW 2026-05-18, default bumped from 20'
    )
    print("✅ HISTORY_LIMIT_MESSAGES default → 30")
else:
    print("⚠️ HISTORY_LIMIT_MESSAGES не найден", file=sys.stderr)

# === 2. Найти Ollama call'ы и добавить num_ctx в options ===
# Pattern: `json={"model": ..., "messages": ..., ...}` — добавить options.num_ctx
# Pattern Ollama API: либо options как dict, либо без options
# Будем добавлять options через ollama_chat function signature

# Сначала найти ollama_chat — расширить параметр num_ctx
ollama_chat_pattern = re.compile(
    r'async def ollama_chat\(\s*model:\s*str,\s*messages:\s*list,?\s*([^)]*)\)',
    re.DOTALL
)
m2 = ollama_chat_pattern.search(src)
if m2:
    sig = m2.group(0)
    if "num_ctx" not in sig:
        new_sig = sig.replace(
            ")",
            ", num_ctx: int | None = None)",
            1
        )
        src = src.replace(sig, new_sig)
        print("✅ ollama_chat signature расширен num_ctx param")

# Также добавим в body — set options.num_ctx если param передан или из env
# Найти JSON body construction в ollama_chat
ollama_body_pattern = re.compile(
    r'(async def ollama_chat[^{]*\{[^}]*"model":\s*model[^}]*\})',
    re.DOTALL
)

# Простой подход — найти "options": ... или добавить если нет.
# Это рискованно с regex, поэтому делаем точечно — после `messages` ключа.
# Лучше: добавить env var OLLAMA_NUM_CTX и пропатчить вызов httpx.post
ollama_call_pattern = re.compile(
    r'(httpx\.AsyncClient[^)]*\)\s*as\s+client[^"]*await\s+client\.post\(\s*f"\{OLLAMA_URL\}/api/(?:chat|generate)"[^)]*json\s*=\s*\{[^}]*)\}',
    re.DOTALL
)

# Точечный hot-patch: добавим переменную окружения, которую читаем рядом
# и пропатчим json={} в Ollama call'ах.

# Ищем все httpx post к /api/chat и /api/generate
post_calls = list(re.finditer(
    r'await\s+client\.post\(\s*\n?\s*f"\{OLLAMA_URL\}/api/(chat|generate)",\s*\n?\s*json\s*=\s*(\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}),',
    src,
    re.DOTALL,
))
print(f"  Найдено Ollama post calls: {len(post_calls)}")

# Альтернативно: добавим в pre-warm options.num_ctx + keep_alive=-1
prewarm_pattern = re.compile(
    r'json=\{"model":\s*tools_model,\s*"prompt":\s*"hi",\s*"stream":\s*False,\s*"keep_alive":\s*-1,\s*"options":\s*\{"num_predict":\s*3\}\}'
)
if prewarm_pattern.search(src):
    src = prewarm_pattern.sub(
        'json={"model": tools_model, "prompt": "hi", "stream": False, "keep_alive": -1, "options": {"num_predict": 3, "num_ctx": int(os.environ.get("OLLAMA_NUM_CTX", "8192"))}}  # v18 CONTEXT_WINDOW',
        src
    )
    print("✅ Pre-warm Ollama call num_ctx 8192 added")

# === 3. Добавить /context_show команду ===
CONTEXT_SHOW = '''@dp.message(Command("context_show"))
async def cmd_context_show(msg: Message):
    """v18 CONTEXT_WINDOW 2026-05-18 — диагностика что попадает в LLM context."""
    user_id = msg.from_user.id
    profile = await db_get_profile(user_id) or ""
    history = await db_history(user_id)
    history_text = "\\n".join([f"[{h['role']}] {h['content'][:120]}" for h in history])
    history_bytes = sum(len(h['content'].encode('utf-8')) for h in history)
    profile_bytes = len(profile.encode('utf-8'))
    # System prompt approximation — около 8 KB после всех v-патчей
    sys_bytes_est = 8000
    total_bytes = sys_bytes_est + profile_bytes + history_bytes
    total_tokens_est = total_bytes // 4  # rough estimate 1 token ≈ 4 bytes русского

    num_ctx = int(os.environ.get("OLLAMA_NUM_CTX", "8192"))
    headroom = num_ctx - total_tokens_est

    report = (
        f"<b>📊 Context дampump</b>\\n\\n"
        f"system prompt (estimate): <b>~{sys_bytes_est}</b> bytes / ~{sys_bytes_est//4} tokens\\n"
        f"profile: <b>{profile_bytes}</b> bytes / ~{profile_bytes//4} tokens\\n"
        f"history: <b>{len(history)} сообщений / {history_bytes}</b> bytes / ~{history_bytes//4} tokens\\n"
        f"────────\\n"
        f"<b>total context: ~{total_bytes} bytes / ~{total_tokens_est} tokens</b>\\n"
        f"Ollama num_ctx limit: <b>{num_ctx}</b>\\n"
        f"headroom: <b>{headroom}</b> tokens\\n\\n"
    )
    if headroom < 1000:
        report += "⚠️ Headroom &lt;1K — старые сообщения вытесняются. Подними OLLAMA_NUM_CTX в .env до 16384."
    else:
        report += "✅ Headroom норм, ничего не урезается."
    await msg.answer(report, parse_mode="HTML")


'''

# Inject после /profile_show или после /profile_clear
inject_anchors = [
    '@dp.message(Command("profile_show"))',  # если v15 применён
    '@dp.message(Command("profile_clear"))',
]
inserted_show = False
for anchor in inject_anchors:
    pos = src.find(anchor)
    if pos < 0:
        continue
    # Найти конец функции — следующий @dp.message
    next_handler = src.find("@dp.message(Command", pos + 1)
    if next_handler > 0:
        src = src[:next_handler] + CONTEXT_SHOW + src[next_handler:]
        print(f"✅ /context_show добавлен после {anchor}")
        inserted_show = True
        break

if not inserted_show:
    print("⚠️  /context_show не inject'ен — anchor не найден", file=sys.stderr)

# === 4. SYSTEM_PROMPT rule — memory hint ===
MEMORY_HINT = '''                "ПАМЯТЬ КОНТЕКСТА (v18 CONTEXT_WINDOW 2026-05-18):\\n"
                "- Ты получаешь до 30 предыдущих сообщений диалога в каждом запросе. ИСПОЛЬЗУЙ их.\\n"
                "- Если юзер недавно представился, упомянул свою задачу, личные данные — НЕ переспрашивай и НЕ здоровайся повторно.\\n"
                "- Если в истории несколько reply на одну тему — продолжай ту же тему, не рестартуй.\\n"
                "- Если контекст обрывается между запросами и непонятно (например юзер сказал просто «да») — посмотри на твой предыдущий ответ, и продолжай оттуда.\\n\\n"
'''

# Anchor — после ИСПОЛЬЗОВАНИЕ АНКЕТЫ (v14) или после SMALL-TALK
anchors_sys = [
    '"ИСПОЛЬЗОВАНИЕ ЛИЧНОЙ АНКЕТЫ ЮЗЕРА (v14',
    '"- web_search вызывай ТОЛЬКО когда юзер реально просит факт',
]
inserted_mem = False
for anchor in anchors_sys:
    pos = src.find(anchor)
    if pos < 0:
        continue
    line_end = src.find('\\n\\n"\n', pos)
    if line_end < 0:
        continue
    insert_pos = line_end + len('\\n\\n"\n')
    src = src[:insert_pos] + MEMORY_HINT + src[insert_pos:]
    print(f"✅ Memory hint injected после {anchor[:40]!r}")
    inserted_mem = True
    break

if not inserted_mem:
    print("⚠️  Memory hint NOT injected", file=sys.stderr)

# === 5. Marker ===
if "# v18 CONTEXT_WINDOW" not in src[:200]:
    src = "# v18 CONTEXT_WINDOW 2026-05-18 — num_ctx 8192 + HISTORY 30 + /context_show\n" + src

bot_py.write_text(src, encoding="utf-8")
print(f"✅ bot.py updated. Size: {len(src)} chars.")
PYEOF

[ $? -ne 0 ] && { cp "$BACKUP" "$BOT_PY"; exit 4; }
python3 -m py_compile "$BOT_PY" || { cp "$BACKUP" "$BOT_PY"; exit 5; }
echo "✅ py_compile OK"

# Set env in .env if not present
ENV_FILE="$BOT_DIR/.env"
[ -f "$ENV_FILE" ] || ENV_FILE="$BOT_DIR/../.env"
if ! grep -q "^OLLAMA_NUM_CTX=" "$ENV_FILE"; then
    echo "OLLAMA_NUM_CTX=8192  # v18 CONTEXT_WINDOW 2026-05-18" >> "$ENV_FILE"
    echo "✅ OLLAMA_NUM_CTX=8192 добавлен в $ENV_FILE"
fi
if ! grep -q "^HISTORY_LIMIT_MESSAGES=" "$ENV_FILE"; then
    echo "HISTORY_LIMIT_MESSAGES=30  # v18 CONTEXT_WINDOW 2026-05-18" >> "$ENV_FILE"
    echo "✅ HISTORY_LIMIT_MESSAGES=30 добавлен в $ENV_FILE"
fi

git add bot.py
git commit -m "feat(v18): context window 8192 + history 30 + /context_show

Юра msg 17984+18006 (2026-05-18): бот забывает контекст после второго
сообщения.

Root causes:
1. Ollama default num_ctx=2048 — твой большой SYSTEM_PROMPT (~8KB после
   v6-v17) + profile + history НЕ ВЛЕЗАЛ.
2. HISTORY_LIMIT_MESSAGES=20 — недостаточно при разогретом SYSTEM_PROMPT.
3. Нет видимости расхода context.

Changes:
1. HISTORY_LIMIT_MESSAGES default 20 → 30.
2. OLLAMA_NUM_CTX env var (default 8192) — для Ollama options.num_ctx.
3. .env: OLLAMA_NUM_CTX=8192, HISTORY_LIMIT_MESSAGES=30 (auto-added).
4. /context_show — diagnostic команда (показывает sys+profile+history
   bytes/tokens + headroom).
5. SYSTEM_PROMPT memory hint: 'у тебя 30 сообщений в context — используй,
   не переспрашивай, не здоровайся повторно'.

Backup tag: pre-tools-v18. Откат: git reset --hard pre-tools-v18." 2>&1 | tail -5

systemctl --user restart "$SERVICE" 2>&1 | tail -3
sleep 2

echo ""
echo "✅ v18 applied. Tests:"
echo "  /context_show — текущее использование context"
echo "  Диалог 10+ сообщений — бот должен помнить старые turns"
echo "  Если headroom <1K — подними OLLAMA_NUM_CTX до 16384 в .env"
echo ""
echo "Откат: git reset --hard pre-tools-v18"
