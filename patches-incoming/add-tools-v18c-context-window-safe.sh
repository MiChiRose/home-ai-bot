#!/usr/bin/env bash
# v18c — БЕЗОПАСНАЯ версия context window fix.
#
# Юра msg 18026: v18b сломал signature `ollama_chat` из-за `list[dict]` с
# квадратными скобками — мой regex не справился со вложенными `[`/`]`.
#
# Новый подход: НЕ менять signature. Внутри ollama_chat вставить блок
# для чтения OLLAMA_NUM_CTX env var и добавления в payload.options.
# Это zero-risk изменение — callsite'ы не трогаем.

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
BOT_PY="$BOT_DIR/bot.py"
SERVICE="${SERVICE:-home-ai-bot.service}"

cd "$BOT_DIR"
[ ! -f "$BOT_PY" ] && { echo "❌ $BOT_PY не найден"; exit 1; }

# Sanity check — bot.py компилится сейчас
python3 -m py_compile "$BOT_PY" || {
    echo "❌ bot.py УЖЕ broken. Сначала восстанови (git reset --hard pre-tools-v18)."
    exit 1
}

BACKUP="$BOT_DIR/bot.py.bak.before-tools-v18c-$(date +%Y%m%d-%H%M%S)"
cp "$BOT_PY" "$BACKUP"
git tag -f pre-tools-v18c "$(git rev-parse HEAD)" 2>/dev/null || true

BOT_PY="$BOT_PY" python3 - <<'PYEOF'
import os, re, sys
from pathlib import Path

bot_py = Path(os.environ["BOT_PY"])
src = bot_py.read_text(encoding="utf-8")

if "CONTEXT_WINDOW v18" in src:
    print("ℹ️  v18c уже применён.")
    sys.exit(0)

# === 1. HISTORY_LIMIT_MESSAGES → 30 ===
m1 = re.search(r'HISTORY_LIMIT_MESSAGES\s*=\s*int\(os\.environ\.get\("HISTORY_LIMIT_MESSAGES",\s*"\d+"\)\)', src)
if m1:
    src = src.replace(m1.group(0),
        'HISTORY_LIMIT_MESSAGES = int(os.environ.get("HISTORY_LIMIT_MESSAGES", "30"))  # v18 CONTEXT_WINDOW 2026-05-18'
    )
    print("✅ HISTORY_LIMIT_MESSAGES → 30")

# === 2. Pre-warm num_ctx ===
prewarm_pattern = re.compile(
    r'json=\{"model":\s*tools_model,\s*"prompt":\s*"hi",\s*"stream":\s*False,\s*"keep_alive":\s*-1,\s*"options":\s*\{"num_predict":\s*3\}\}'
)
if prewarm_pattern.search(src):
    src = prewarm_pattern.sub(
        'json={"model": tools_model, "prompt": "hi", "stream": False, "keep_alive": -1, "options": {"num_predict": 3, "num_ctx": int(os.environ.get("OLLAMA_NUM_CTX", "8192"))}}  # v18 CONTEXT_WINDOW',
        src
    )
    print("✅ Pre-warm num_ctx 8192")

# === 3. ИНжект options.num_ctx в payload ВНУТРИ ollama_chat (без signature change) ===
# Найти 'payload = {' блок внутри ollama_chat и добавить num_ctx после "stream": False
payload_pattern = re.compile(
    r'(payload\s*=\s*\{\s*\n\s*"model":\s*model,\s*\n\s*"messages":\s*messages,\s*\n\s*"stream":\s*False,\s*\n\s*\})',
    re.MULTILINE
)
m_payload = payload_pattern.search(src)
if m_payload:
    old_payload = m_payload.group(0)
    new_payload = old_payload.replace(
        '"stream": False,',
        '"stream": False,\n        "options": {"num_ctx": int(os.environ.get("OLLAMA_NUM_CTX", "8192"))},  # v18 CONTEXT_WINDOW'
    )
    src = src.replace(old_payload, new_payload)
    print("✅ ollama_chat payload теперь добавляет options.num_ctx (от OLLAMA_NUM_CTX env)")
else:
    print("⚠️  ollama_chat payload pattern не найден — num_ctx в chat skipped", file=sys.stderr)

# === 4. /context_show команда ===
CONTEXT_SHOW = '''@dp.message(Command("context_show"))
async def cmd_context_show(msg: Message):
    """v18 CONTEXT_WINDOW 2026-05-18 — диагностика context."""
    user_id = msg.from_user.id
    profile = await db_get_profile(user_id) or ""
    history = await db_history(user_id)
    history_bytes = sum(len(h['content'].encode('utf-8')) for h in history)
    profile_bytes = len(profile.encode('utf-8'))
    sys_bytes_est = 8000
    total_bytes = sys_bytes_est + profile_bytes + history_bytes
    total_tokens_est = total_bytes // 4
    num_ctx = int(os.environ.get("OLLAMA_NUM_CTX", "8192"))
    headroom = num_ctx - total_tokens_est
    report = (
        f"<b>📊 Context дamp</b>\\n\\n"
        f"system prompt (est): ~{sys_bytes_est} bytes\\n"
        f"profile: {profile_bytes} bytes\\n"
        f"history: {len(history)} msgs / {history_bytes} bytes\\n"
        f"────────\\n"
        f"<b>total: ~{total_bytes} bytes / ~{total_tokens_est} tokens</b>\\n"
        f"Ollama num_ctx: {num_ctx}\\n"
        f"headroom: <b>{headroom}</b> tokens\\n\\n"
    )
    if headroom < 1000:
        report += "⚠️ headroom &lt;1K — старое вытесняется. Подними OLLAMA_NUM_CTX=16384 в .env."
    else:
        report += "✅ headroom OK."
    await msg.answer(report, parse_mode="HTML")


'''

clear_pos = src.find('@dp.message(Command("profile_clear"))')
if clear_pos >= 0:
    next_handler = src.find('@dp.message(Command', clear_pos + 30)
    if next_handler > 0 and "/context_show" not in src[clear_pos:next_handler]:
        src = src[:next_handler] + CONTEXT_SHOW + src[next_handler:]
        print("✅ /context_show injected после profile_clear")

# === 5. Memory hint ===
MEMORY_HINT = '''                "ПАМЯТЬ КОНТЕКСТА (v18 CONTEXT_WINDOW 2026-05-18):\\n"
                "- Ты получаешь до 30 предыдущих сообщений диалога. ИСПОЛЬЗУЙ их.\\n"
                "- Если юзер недавно представился — НЕ переспрашивай и НЕ здоровайся повторно.\\n"
                "- Продолжай начатую тему, не рестартуй после reply.\\n"
                "- На неоднозначный reply («да», «ок») — смотри свой предыдущий ответ.\\n\\n"
'''
anchor_sys = '"ИСПОЛЬЗОВАНИЕ ЛИЧНОЙ АНКЕТЫ ЮЗЕРА (v14'
pos = src.find(anchor_sys)
if pos >= 0 and "ПАМЯТЬ КОНТЕКСТА" not in src:
    line_end = src.find('\\n\\n"\n', pos)
    if line_end > 0:
        insert_pos = line_end + len('\\n\\n"\n')
        src = src[:insert_pos] + MEMORY_HINT + src[insert_pos:]
        print("✅ Memory hint injected")

# === Marker ===
if "# v18 CONTEXT_WINDOW" not in src[:200]:
    src = "# v18 CONTEXT_WINDOW 2026-05-18 — num_ctx 8192 + HISTORY 30 + /context_show\n" + src

bot_py.write_text(src, encoding="utf-8")
print(f"✅ bot.py updated. Size: {len(src)} chars.")
PYEOF

[ $? -ne 0 ] && { cp "$BACKUP" "$BOT_PY"; echo "❌ Python step failed"; exit 4; }

python3 -m py_compile "$BOT_PY" || {
    echo "❌ py_compile failed. Restoring backup."
    cp "$BACKUP" "$BOT_PY"
    exit 5
}
echo "✅ py_compile OK"

# .env
ENV_FILE="$BOT_DIR/.env"
[ -f "$ENV_FILE" ] || ENV_FILE="$BOT_DIR/../.env"
if ! grep -q "^OLLAMA_NUM_CTX=" "$ENV_FILE"; then
    echo "OLLAMA_NUM_CTX=8192  # v18 CONTEXT_WINDOW 2026-05-18" >> "$ENV_FILE"
    echo "✅ OLLAMA_NUM_CTX=8192 → .env"
fi
if ! grep -q "^HISTORY_LIMIT_MESSAGES=" "$ENV_FILE"; then
    echo "HISTORY_LIMIT_MESSAGES=30  # v18 CONTEXT_WINDOW 2026-05-18" >> "$ENV_FILE"
    echo "✅ HISTORY_LIMIT_MESSAGES=30 → .env"
fi

git add bot.py
git commit -m "feat(v18c): context window 8192 + history 30 + /context_show (safe, no signature change)

v18/v18b ломали signature ollama_chat из-за list[dict] и multi-line.
v18c использует ВНУТРЕННИЙ инжект options.num_ctx через payload, не
трогая signature функции. Callsite'ы не модифицируются.

Backup tag: pre-tools-v18c. Откат: git reset --hard pre-tools-v18c." 2>&1 | tail -5

systemctl --user restart "$SERVICE" 2>&1 | tail -3
sleep 2
systemctl --user status "$SERVICE" --no-pager 2>&1 | head -6

echo ""
echo "✅ v18c applied. Tests:"
echo "  /context_show — diagnostic"
echo "  10+ сообщений диалог — бот должен помнить старые turns"
echo "  Если headroom <1K в context_show — подними OLLAMA_NUM_CTX=16384 в .env"
echo ""
echo "Откат: git reset --hard pre-tools-v18c"
