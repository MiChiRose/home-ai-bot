#!/usr/bin/env bash
# 400 не уходит — нужно поймать ТОЧНЫЙ payload который бот шлёт в Ollama.
# Прямой curl с минимальным payload вернул 200, значит проблема в payload бота.
#
# Стратегия: включаем Ollama debug request logging (OLLAMA_DEBUG_LOG_REQUESTS=true)
# через drop-in override, рестарт Ollama, и пока Юра пишет боту — журнал
# фиксирует точный body запроса + ответ 400.
#
# Запуск БЕЗ sudo (но потребует sudo пароль для systemctl ollama):
#   bash ./trace-bot-ollama-payload.sh
# После запуска — Юра пишет боту любое сообщение в Telegram, скрипт следит
# 90 секунд и собирает трассу.

set -u
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$HOME/Documents/bot-ollama-trace-$STAMP.log"
mkdir -p "$HOME/Documents"
exec > >(tee -a "$LOG") 2>&1

echo "===================================================================="
echo "  Trace bot → Ollama payload (поймать что именно вызывает 400)"
echo "  $(date -Iseconds) — лог: $LOG"
echo "===================================================================="

echo
echo "--- 1. Включаю Ollama debug request logging ---"
DROPIN="/etc/systemd/system/ollama.service.d/zz-evan-defaults.conf"
if [ -f "$DROPIN" ]; then
    if grep -q "OLLAMA_DEBUG_LOG_REQUESTS" "$DROPIN"; then
        echo "[+] OLLAMA_DEBUG_LOG_REQUESTS уже есть в $DROPIN"
    else
        sudo cp -a "$DROPIN" "$DROPIN.bak-$STAMP"
        echo 'Environment="OLLAMA_DEBUG_LOG_REQUESTS=true"' | sudo tee -a "$DROPIN" >/dev/null
        echo "[+] добавил OLLAMA_DEBUG_LOG_REQUESTS=true в $DROPIN"
    fi
else
    echo "[!] $DROPIN не существует — что-то странно. Прерываю."
    exit 1
fi

echo
echo "--- 2. daemon-reload + restart ollama ---"
sudo systemctl daemon-reload
sudo systemctl restart ollama.service
sleep 5
echo "Статус ollama:"
sudo systemctl is-active ollama.service && echo "[+] active" || echo "[!] not active"

echo
echo "--- 3. Подготовка: следим за журналом 90 секунд ---"
echo
echo "🔴 СЕЙЧАС: открой Telegram и напиши боту любой вопрос (например 'привет')."
echo "   Бот пошлёт запрос в Ollama, мы поймаем точный body + ответ 400."
echo "   Тайм-лимит: 90 секунд."
echo

# Tail ollama journal + bot stderr параллельно, ждём 90 сек.
sudo journalctl -u ollama.service --since "10 seconds ago" -f --no-pager > /tmp/ollama-trace.log 2>&1 &
JOURNAL_PID=$!

tail -F "$HOME/ai-assistant/logs/bot-stderr.log" 2>/dev/null > /tmp/bot-stderr-trace.log &
STDERR_PID=$!

tail -F "$HOME/ai-assistant/logs/bot-stdout.log" 2>/dev/null > /tmp/bot-stdout-trace.log &
STDOUT_PID=$!

for i in 90 80 70 60 50 40 30 20 10 5 4 3 2 1; do
    sleep 5
    [ "$i" -le 10 ] && echo "осталось ~${i}с... пиши боту, если ещё не написал!"
done

kill $JOURNAL_PID 2>/dev/null
kill $STDERR_PID 2>/dev/null
kill $STDOUT_PID 2>/dev/null
wait 2>/dev/null

echo
echo "--- 4. ВАЖНО: что нашёл в ollama journal (последние 100 строк) ---"
echo "(ищу POST /api/chat запросы и 400 ответы)"
grep -E "POST /api/chat|400 Bad Request|status=400|message:|error|panic" /tmp/ollama-trace.log | head -40 || echo "(не нашёл match'а)"
echo
echo "--- 4a. Полный tail ollama journal ---"
tail -50 /tmp/ollama-trace.log

echo
echo "--- 5. bot-stderr — что свежее ---"
tail -40 /tmp/bot-stderr-trace.log

echo
echo "--- 6. bot-stdout — что свежее ---"
tail -40 /tmp/bot-stdout-trace.log

echo
echo "--- 7. Откатываю OLLAMA_DEBUG_LOG_REQUESTS (debug не должен оставаться) ---"
if [ -f "$DROPIN.bak-$STAMP" ]; then
    sudo cp "$DROPIN.bak-$STAMP" "$DROPIN"
    sudo systemctl daemon-reload
    sudo systemctl restart ollama.service
    echo "[+] откат drop-in OK + ollama restart"
fi

rm -f /tmp/ollama-trace.log /tmp/bot-stderr-trace.log /tmp/bot-stdout-trace.log

echo
echo "===================================================================="
echo "  ГОТОВО. Полный лог: $LOG"
echo "  Пришли его Эвану — по ollama debug body будет видно почему 400."
echo "===================================================================="
