#!/usr/bin/env bash
# send-systemprompt-snippet.sh
# Юра msg 17871 (2026-05-18): нужно получить snippet bot.py около SYSTEM_PROMPT
# в Telegram (Юра физически не у сервера).
#
# Скрипт находит SYSTEM_PROMPT в bot.py, отправляет +/- 30 строк контекста через
# Telegram Bot API в DM Юры (admin user).
#
# Apply: bash send-systemprompt-snippet.sh ИЛИ через /run_patch.

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
BOT_PY="$BOT_DIR/bot.py"

[ ! -f "$BOT_PY" ] && { echo "❌ $BOT_PY не найден"; exit 1; }

# Load .env для BOT_TOKEN
ENV_FILE="$BOT_DIR/.env"
[ -f "$ENV_FILE" ] || ENV_FILE="$BOT_DIR/../.env"
[ -f "$ENV_FILE" ] || { echo "❌ .env не найден"; exit 2; }

# shellcheck source=/dev/null
set -a
. "$ENV_FILE"
set +a

BOT_TOKEN="${BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-}}"
[ -z "$BOT_TOKEN" ] && { echo "❌ BOT_TOKEN не выгружен из .env"; exit 3; }

# Юра ADMIN_USER_ID — try .env first, fallback hardcoded
ADMIN_ID="${ADMIN_USER_ID:-${ADMIN_IDS:-263280027}}"
# Если ADMIN_IDS - список через запятую, берём первый
ADMIN_ID="${ADMIN_ID%%,*}"

echo "==> ADMIN_ID для отправки: $ADMIN_ID"
echo "==> BOT_PY: $BOT_PY ($(wc -l < "$BOT_PY") строк)"

# Find anchor: SYSTEM_PROMPT начало (обычно "ПРОАКТИВНОСТЬ И TOOL-USE" или маркер «system_prompt»)
ANCHOR_LINE="$(grep -nE 'ПРОАКТИВНОСТЬ И TOOL-USE|БЕЛАРУСЬ — НЕЙТРАЛЬН|web_search.*description|SYSTEM_PROMPT|system_prompt\s*=' "$BOT_PY" | head -1 | cut -d: -f1)"

if [ -z "$ANCHOR_LINE" ]; then
    echo "❌ Anchor не найден в bot.py"
    exit 4
fi

echo "==> Anchor строка: $ANCHOR_LINE"

# Возьмём ±50 строк вокруг anchor
START=$((ANCHOR_LINE > 30 ? ANCHOR_LINE - 30 : 1))
END=$((ANCHOR_LINE + 70))

SNIPPET="$(sed -n "${START},${END}p" "$BOT_PY")"
SNIPPET_BYTES="$(echo -n "$SNIPPET" | wc -c)"

echo "==> Snippet: строки $START..$END ($SNIPPET_BYTES bytes)"

# Telegram message limit — 4096 chars. Если больше — отправим файлом.
if [ "$SNIPPET_BYTES" -gt 3800 ]; then
    echo "==> Snippet >3800 bytes, отправляю файлом..."
    TMP_FILE="$(mktemp --suffix=.txt /tmp/bot-snippet-XXXXXX)"
    {
        echo "# Snippet из bot.py строки $START..$END (anchor на строке $ANCHOR_LINE)"
        echo "# Сгенерировано $(date)"
        echo ""
        echo "$SNIPPET"
    } > "$TMP_FILE"

    HTTP_CODE="$(curl -sS -o /tmp/tg-resp.json -w "%{http_code}" \
        -F "chat_id=$ADMIN_ID" \
        -F "document=@$TMP_FILE" \
        -F "caption=bot.py snippet: lines $START..$END (anchor $ANCHOR_LINE — system_prompt area)" \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument")"
    echo "==> Telegram HTTP=$HTTP_CODE"
    cat /tmp/tg-resp.json | head -c 500; echo
    rm -f "$TMP_FILE" /tmp/tg-resp.json
else
    echo "==> Snippet ≤3800 bytes, отправляю текстом..."
    # Escape для Telegram (просто без parse_mode чтобы избежать markdown problems)
    PAYLOAD="$(python3 -c "
import json, sys
text = '''# Snippet bot.py lines $START..$END (anchor line $ANCHOR_LINE)

$SNIPPET'''
print(json.dumps({'chat_id': '$ADMIN_ID', 'text': text[:4000]}))
")"
    HTTP_CODE="$(curl -sS -o /tmp/tg-resp.json -w "%{http_code}" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage")"
    echo "==> Telegram HTTP=$HTTP_CODE"
    cat /tmp/tg-resp.json | head -c 500; echo
    rm -f /tmp/tg-resp.json
fi

echo "✅ Done."
