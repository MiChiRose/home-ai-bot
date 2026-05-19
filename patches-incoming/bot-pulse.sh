#!/usr/bin/env bash
# Минимальная проверка: жив ли бот, что в его свежих логах. Без sudo.
# Запуск: bash ./bot-pulse.sh

BOT_DIR="$HOME/ai-assistant"
BOT_SERVICE="home-ai-bot.service"

echo "=== $(date -Iseconds) bot pulse ==="
echo
echo "--- is-active ---"
systemctl --user is-active "$BOT_SERVICE"
echo
echo "--- PID + uptime ---"
PID=$(systemctl --user show -p MainPID --value "$BOT_SERVICE" 2>/dev/null)
echo "PID: $PID"
[ -n "$PID" ] && [ "$PID" != "0" ] && ps -p "$PID" -o pid,etime,rss,cmd
echo
echo "--- journalctl --user последние 25 строк ---"
journalctl --user -u "$BOT_SERVICE" -n 25 --no-pager 2>&1 | tail -25
echo
echo "--- bot-stderr.log последние 30 строк ---"
tail -30 "$BOT_DIR/logs/bot-stderr.log" 2>/dev/null
echo
echo "--- bot-stdout.log последние 30 строк ---"
tail -30 "$BOT_DIR/logs/bot-stdout.log" 2>/dev/null
echo
echo "=== готово ==="
