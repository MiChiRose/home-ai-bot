#!/usr/bin/env bash
# send-bot-logs-snippet.sh
# Юра msg 17906 (2026-05-18) — он не у компа, нужно вытянуть логи через скрипт.
#
# Скрипт собирает journalctl за последние 10 минут с фильтром по voice/whisper/error,
# плюс tail bot.log, и шлёт админу через Telegram Bot API как .txt файл.
#
# Apply: /run_patch send-bot-logs-snippet.sh

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
SERVICE="${SERVICE:-home-ai-bot.service}"

ENV_FILE="$BOT_DIR/.env"
[ -f "$ENV_FILE" ] || ENV_FILE="$BOT_DIR/../.env"
[ -f "$ENV_FILE" ] || { echo "❌ .env не найден"; exit 2; }

set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

BOT_TOKEN="${BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-}}"
[ -z "$BOT_TOKEN" ] && { echo "❌ BOT_TOKEN не выгружен"; exit 3; }

ADMIN_ID="${ADMIN_USER_ID:-${ADMIN_IDS:-263280027}}"
ADMIN_ID="${ADMIN_ID%%,*}"

echo "==> ADMIN_ID: $ADMIN_ID"
echo "==> SERVICE: $SERVICE"

OUT="$(mktemp --suffix=.txt /tmp/bot-logs-XXXXXX)"
{
    echo "=========================================="
    echo "Bot logs snapshot $(date)"
    echo "=========================================="
    echo ""
    echo "--- systemctl status (head 15) ---"
    systemctl --user status "$SERVICE" --no-pager 2>&1 | head -15
    echo ""
    echo "--- journalctl last 10 min (voice / whisper / error / Traceback) ---"
    journalctl --user -u "$SERVICE" --since "10 minutes ago" --no-pager 2>&1 | \
        grep -iE "voice|whisper|error|traceback|exception|failed|ERROR|STT|transcribe" | tail -80
    echo ""
    echo "--- journalctl last 20 lines (raw) ---"
    journalctl --user -u "$SERVICE" --no-pager -n 20 2>&1
    echo ""
    echo "--- bot.log tail (if exists) ---"
    [ -f "$BOT_DIR/bot.log" ] && tail -30 "$BOT_DIR/bot.log" || echo "(no bot.log)"
} > "$OUT" 2>&1

SIZE="$(wc -c < "$OUT")"
echo "==> Сгенерирован лог $SIZE байт"

curl -sS -o /tmp/tg-resp.json -w "HTTP=%{http_code}\n" \
    -F "chat_id=$ADMIN_ID" \
    -F "document=@$OUT" \
    -F "caption=Bot logs snapshot $(date '+%H:%M %d.%m')" \
    "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument"

head -c 400 /tmp/tg-resp.json
echo ""
rm -f "$OUT" /tmp/tg-resp.json

echo "✅ Done."
