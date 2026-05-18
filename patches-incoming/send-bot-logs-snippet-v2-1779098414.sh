#!/usr/bin/env bash
# send-bot-logs-snippet-v2.sh
# v2: убрал `set -e` + добавил per-step status + fallback'и + verbose stderr.
# v1 (msg 17910) тихо упал — скорее всего journalctl/curl ушли на rc!=0 без вывода.

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
SERVICE="${SERVICE:-home-ai-bot.service}"

ENV_FILE="$BOT_DIR/.env"
[ -f "$ENV_FILE" ] || ENV_FILE="$BOT_DIR/../.env"

echo "==> step 1: load .env"
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck source=/dev/null
    . "$ENV_FILE" 2>&1
    set +a
    echo "    ✅ .env loaded from $ENV_FILE"
else
    echo "    ❌ .env not found"
    exit 2
fi

BOT_TOKEN="${BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-}}"
if [ -z "$BOT_TOKEN" ]; then
    echo "    ❌ BOT_TOKEN/TELEGRAM_BOT_TOKEN не выгружены"
    exit 3
fi
echo "    ✅ BOT_TOKEN length=${#BOT_TOKEN}"

ADMIN_ID="${ADMIN_USER_ID:-${ADMIN_IDS:-263280027}}"
ADMIN_ID="${ADMIN_ID%%,*}"
echo "    ✅ ADMIN_ID=$ADMIN_ID"
echo "    ✅ SERVICE=$SERVICE"

OUT="$(mktemp --suffix=.txt /tmp/bot-logs-XXXXXX)"
echo "==> step 2: collect data to $OUT"

{
    echo "=========================================="
    echo "Bot logs snapshot $(date)"
    echo "=========================================="
    echo ""

    echo "--- step 2a: systemctl --user status (head 15) ---"
    if systemctl --user status "$SERVICE" --no-pager > /tmp/_s.txt 2>&1; then
        head -15 /tmp/_s.txt
    else
        echo "❌ systemctl --user status FAILED rc=$?"
        cat /tmp/_s.txt
    fi
    rm -f /tmp/_s.txt
    echo ""

    echo "--- step 2b: journalctl --user filter (last 10 min) ---"
    if journalctl --user -u "$SERVICE" --since "10 minutes ago" --no-pager > /tmp/_j.txt 2>&1; then
        FILTERED=$(grep -iE "voice|whisper|error|traceback|exception|failed|stt|transcribe" /tmp/_j.txt | tail -80)
        if [ -z "$FILTERED" ]; then
            echo "(нет совпадений по voice/whisper/error)"
        else
            echo "$FILTERED"
        fi
    else
        echo "❌ journalctl FAILED rc=$? — нет прав или XDG_RUNTIME_DIR не настроен"
        echo "(пробую bot.log fallback ниже)"
    fi
    rm -f /tmp/_j.txt
    echo ""

    echo "--- step 2c: journalctl raw last 30 lines ---"
    journalctl --user -u "$SERVICE" --no-pager -n 30 2>&1
    echo ""

    echo "--- step 2d: bot.log tail (если есть) ---"
    if [ -f "$BOT_DIR/bot.log" ]; then
        tail -40 "$BOT_DIR/bot.log"
    else
        echo "(нет $BOT_DIR/bot.log)"
        # Поищем альтернативные пути
        for alt in "$HOME/bot.log" "/var/log/home-ai-bot.log" "$BOT_DIR/logs/bot.log"; do
            if [ -f "$alt" ]; then
                echo "Найден альтернативный лог: $alt"
                tail -40 "$alt"
                break
            fi
        done
    fi
    echo ""

    echo "--- step 2e: process info ---"
    pgrep -af "bot\.py\|home-ai-bot" 2>&1 | head -5
    echo ""

    echo "--- step 2f: tools/voice_stt module presence ---"
    ls -la "$BOT_DIR/tools/voice_stt"* 2>&1
    echo ""
    if [ -f "$BOT_DIR/tools/voice_stt.py" ]; then
        head -30 "$BOT_DIR/tools/voice_stt.py" 2>&1
    fi
} > "$OUT" 2>&1

SIZE=$(wc -c < "$OUT")
echo "    ✅ Собрал $SIZE байт в $OUT"

echo "==> step 3: sendDocument to Telegram"
curl -sS -o /tmp/tg-resp.json -w "    HTTP=%{http_code}\n" \
    -F "chat_id=$ADMIN_ID" \
    -F "document=@$OUT" \
    -F "caption=Bot logs v2 — $(date '+%H:%M:%S %d.%m')" \
    "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument"
CURL_RC=$?
echo "    curl rc=$CURL_RC"

echo "==> step 4: Telegram response"
if [ -f /tmp/tg-resp.json ]; then
    head -c 600 /tmp/tg-resp.json
    echo ""
    OK=$(python3 -c "import json; print(json.load(open('/tmp/tg-resp.json')).get('ok'))" 2>&1)
    echo "    ok=$OK"
fi

rm -f "$OUT" /tmp/tg-resp.json
echo "==> Done."
