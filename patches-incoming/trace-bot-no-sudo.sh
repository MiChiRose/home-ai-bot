#!/usr/bin/env bash
# Версия без sudo. Не трогаем Ollama config — только смотрим что бот сам пишет
# в свои логи во время твоего запроса. Bot pipes stderr/stdout в файлы
# через systemd unit, в них обычно видно request к Ollama и response 400.
#
# Запуск:  bash ./trace-bot-no-sudo.sh
# После запуска — Юра пишет боту любой вопрос в Telegram, скрипт следит
# 60 секунд и собирает свежие строки.

set -u
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$HOME/Documents/bot-trace-nosudo-$STAMP.log"
BOT_DIR="$HOME/ai-assistant"
BOT_SERVICE="home-ai-bot.service"

mkdir -p "$HOME/Documents"
exec > >(tee -a "$LOG") 2>&1

echo "===================================================================="
echo "  Trace bot 400 — only user-side, no sudo"
echo "  $(date -Iseconds) — лог: $LOG"
echo "===================================================================="

echo
echo "--- 1. Размер логов до теста ---"
STDERR_BEFORE=$(stat -c%s "$BOT_DIR/logs/bot-stderr.log" 2>/dev/null || echo 0)
STDOUT_BEFORE=$(stat -c%s "$BOT_DIR/logs/bot-stdout.log" 2>/dev/null || echo 0)
echo "stderr: $STDERR_BEFORE bytes"
echo "stdout: $STDOUT_BEFORE bytes"

echo
echo "--- 2. Bot service статус ---"
systemctl --user is-active "$BOT_SERVICE" 2>&1
PID=$(systemctl --user show -p MainPID --value "$BOT_SERVICE" 2>/dev/null)
echo "PID: $PID"

echo
echo "--- 3. Ждём твой запрос боту, 60 секунд ---"
echo
echo "🔴 СЕЙЧАС: открой Telegram, напиши боту любой вопрос."
echo "   Скрипт будет следить за логами + journalctl --user 60 секунд."
echo

# Tail user journal + bot stderr/stdout параллельно.
journalctl --user -u "$BOT_SERVICE" --since "5 seconds ago" -f --no-pager > /tmp/bot-journal-trace.log 2>&1 &
JP=$!

tail -F "$BOT_DIR/logs/bot-stderr.log" 2>/dev/null > /tmp/bot-stderr-trace.log &
SP=$!

tail -F "$BOT_DIR/logs/bot-stdout.log" 2>/dev/null > /tmp/bot-stdout-trace.log &
OP=$!

for i in 60 50 40 30 20 10 5 4 3 2 1; do
    sleep 5
    if [ "$i" -le 10 ]; then
        echo "осталось ~${i}с... пиши боту, если ещё не!"
    fi
done

kill $JP $SP $OP 2>/dev/null
wait 2>/dev/null

echo
echo "--- 4. journalctl --user bot — последние 60 строк ---"
tail -60 /tmp/bot-journal-trace.log

echo
echo "--- 5. bot-stderr новые строки (с момента старта скрипта) ---"
STDERR_AFTER=$(stat -c%s "$BOT_DIR/logs/bot-stderr.log" 2>/dev/null || echo 0)
DIFF=$((STDERR_AFTER - STDERR_BEFORE))
echo "Прирост: $DIFF bytes"
if [ "$DIFF" -gt 0 ]; then
    tail -c "$DIFF" "$BOT_DIR/logs/bot-stderr.log"
fi

echo
echo "--- 6. bot-stdout новые строки ---"
STDOUT_AFTER=$(stat -c%s "$BOT_DIR/logs/bot-stdout.log" 2>/dev/null || echo 0)
DIFF=$((STDOUT_AFTER - STDOUT_BEFORE))
echo "Прирост: $DIFF bytes"
if [ "$DIFF" -gt 0 ]; then
    tail -c "$DIFF" "$BOT_DIR/logs/bot-stdout.log"
fi

echo
echo "--- 7. Grep Ollama / 400 / chat / payload в новых строках ---"
{
  tail -c 50000 "$BOT_DIR/logs/bot-stderr.log" 2>/dev/null
  tail -c 50000 "$BOT_DIR/logs/bot-stdout.log" 2>/dev/null
} | grep -iE "ollama|/api/chat|400|bad request|payload|httpx|aiohttp|client error" | tail -30

rm -f /tmp/bot-journal-trace.log /tmp/bot-stderr-trace.log /tmp/bot-stdout-trace.log

echo
echo "===================================================================="
echo "  ГОТОВО. Лог: $LOG"
echo "  Пришли его Эвану — по новым строкам станет ясно что валит."
echo "===================================================================="
