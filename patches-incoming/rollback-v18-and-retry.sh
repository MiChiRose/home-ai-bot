#!/usr/bin/env bash
# rollback-v18-and-retry.sh — откатить ломаный v18 и применить fixed версию.
#
# Юра msg 18020: v18 sub'нул `)` в multi-line ollama_chat signature и получил
# `list,\n    , num_ctx:` — два запятых подряд → SyntaxError.
# Бот не запускается.
#
# Этот скрипт:
# 1. git reset --hard pre-tools-v18 — откат к до-v18 состоянию
# 2. Применяет ИСПРАВЛЕННЫЙ v18 с правильным AST-парсингом

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
BOT_PY="$BOT_DIR/bot.py"
SERVICE="${SERVICE:-home-ai-bot.service}"

cd "$BOT_DIR"

# === ROLLBACK ===
echo "==> Step 1: rollback ломаного v18"
if git tag --list | grep -q "^pre-tools-v18$"; then
    git reset --hard pre-tools-v18
    echo "✅ Откатились к pre-tools-v18"
else
    echo "❌ Tag pre-tools-v18 не найден. Не могу откатиться."
    exit 1
fi

python3 -m py_compile "$BOT_PY" || {
    echo "❌ После отката py_compile всё ещё fail. Что-то странное."
    exit 2
}
echo "✅ py_compile после отката OK"

# === Re-apply FIXED v18 ===
echo ""
echo "==> Step 2: применяем исправленный v18"

BACKUP="$BOT_DIR/bot.py.bak.before-tools-v18b-$(date +%Y%m%d-%H%M%S)"
cp "$BOT_PY" "$BACKUP"
git tag -f pre-tools-v18b "$(git rev-parse HEAD)" 2>/dev/null || true

BOT_PY="$BOT_PY" python3 - <<'PYEOF'
import os, re, sys
from pathlib import Path

bot_py = Path(os.environ["BOT_PY"])
src = bot_py.read_text(encoding="utf-8")

if "CONTEXT_WINDOW v18" in src:
    print("ℹ️  v18b уже применён.")
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

# === 3. ИСПРАВЛЕНО — поиск настоящей сигнатуры ollama_chat ===
# Найти определение через AST-friendly regex (закрывающая `)` ИМЕННО перед `-> tuple` или `:`)
ollama_chat_def = re.compile(
    r'async def ollama_chat\(\s*model:\s*str,\s*messages:\s*list,?\s*([^)]*?)\s*\)\s*(->\s*[^:]+)?\s*:',
    re.DOTALL
)
m2 = ollama_chat_def.search(src)
if m2 and "num_ctx" not in m2.group(0):
    full_def = m2.group(0)
    # Reconstruct cleanly
    existing_params = m2.group(1).strip()
    ret_type = m2.group(2) or ""
    if existing_params:
        new_def = f"async def ollama_chat(\n    model: str,\n    messages: list,\n    {existing_params},\n    num_ctx: int | None = None,\n) {ret_type}:"
    else:
        new_def = f"async def ollama_chat(\n    model: str,\n    messages: list,\n    num_ctx: int | None = None,\n) {ret_type}:"
    src = src.replace(full_def, new_def)
    print("✅ ollama_chat signature расширена num_ctx (clean reconstruction)")
elif "num_ctx" in (m2.group(0) if m2 else ""):
    print("ℹ️  ollama_chat уже имеет num_ctx")
else:
    print("⚠️  ollama_chat не найден — num_ctx не добавлен в signature")

# === 4. /context_show ===
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

# Find /profile_clear handler END (start of next handler)
clear_pos = src.find('@dp.message(Command("profile_clear"))')
if clear_pos >= 0:
    next_handler = src.find('@dp.message(Command', clear_pos + 30)
    if next_handler > 0:
        src = src[:next_handler] + CONTEXT_SHOW + src[next_handler:]
        print("✅ /context_show injected после profile_clear")
    else:
        print("⚠️ next handler после profile_clear не найден")
else:
    print("⚠️ profile_clear не найден — /context_show skipped")

# === 5. Memory hint в SYSTEM_PROMPT ===
MEMORY_HINT = '''                "ПАМЯТЬ КОНТЕКСТА (v18 CONTEXT_WINDOW 2026-05-18):\\n"
                "- Ты получаешь до 30 предыдущих сообщений диалога. ИСПОЛЬЗУЙ их.\\n"
                "- Если юзер недавно представился — НЕ переспрашивай и НЕ здоровайся повторно.\\n"
                "- Продолжай начатую тему, не рестартуй после reply.\\n"
                "- На неоднозначный reply («да», «ок») — смотри свой предыдущий ответ.\\n\\n"
'''

anchor_sys = '"ИСПОЛЬЗОВАНИЕ ЛИЧНОЙ АНКЕТЫ ЮЗЕРА (v14'
pos = src.find(anchor_sys)
if pos >= 0:
    line_end = src.find('\\n\\n"\n', pos)
    if line_end > 0:
        insert_pos = line_end + len('\\n\\n"\n')
        if "ПАМЯТЬ КОНТЕКСТА" not in src:
            src = src[:insert_pos] + MEMORY_HINT + src[insert_pos:]
            print("✅ Memory hint injected")

# === Marker ===
if "# v18 CONTEXT_WINDOW" not in src[:200]:
    src = "# v18 CONTEXT_WINDOW 2026-05-18 — num_ctx 8192 + HISTORY 30 + /context_show\n" + src

bot_py.write_text(src, encoding="utf-8")
print(f"✅ bot.py updated. Size: {len(src)} chars.")
PYEOF

[ $? -ne 0 ] && { cp "$BACKUP" "$BOT_PY"; echo "❌ Python step failed, restored"; exit 4; }

python3 -m py_compile "$BOT_PY" || {
    echo "❌ py_compile failed после v18b. Restoring backup."
    cp "$BACKUP" "$BOT_PY"
    exit 5
}
echo "✅ py_compile OK"

# .env update
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
git commit -m "feat(v18b): context window 8192 + history 30 + /context_show (fixed from v18)

v18 ломал ollama_chat signature из-за multi-line replace. v18b использует
clean reconstruction после AST-friendly regex.

Backup tag: pre-tools-v18b. Откат: git reset --hard pre-tools-v18b." 2>&1 | tail -5

systemctl --user restart "$SERVICE" 2>&1 | tail -3
sleep 2
systemctl --user status "$SERVICE" --no-pager 2>&1 | head -6

echo ""
echo "✅ v18b applied successfully."
echo "Откат: git reset --hard pre-tools-v18b"
