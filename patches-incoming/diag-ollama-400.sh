#!/usr/bin/env bash
# Бот живёт но Ollama возвращает 400 Bad Request на /api/chat.
# Этот скрипт:
#   1. Выдёргивает последний request payload бота из stderr-лога
#   2. Список доступных моделей через /api/tags
#   3. Прямой curl /api/chat с разными payload (минимальный → с options) →
#      покажет какое именно поле ломается
#   4. Журнал ollama во время этих запросов
#
# Запуск БЕЗ sudo:  bash ./diag-ollama-400.sh
# Лог в ~/Documents/

set -u
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$HOME/Documents/ollama-400-$STAMP.log"
BOT_DIR="$HOME/ai-assistant"
BOT_SERVICE="home-ai-bot.service"

mkdir -p "$HOME/Documents"
exec > >(tee -a "$LOG") 2>&1

echo "===================================================================="
echo "  Ollama 400 diagnostic"
echo "  $(date -Iseconds) — лог: $LOG"
echo "===================================================================="

echo
echo "--- 1. Версии ---"
ollama --version
curl -s http://127.0.0.1:11434/api/version | head -1

echo
echo "--- 2. Доступные модели (то что есть в /api/tags) ---"
curl -s http://127.0.0.1:11434/api/tags | python3 -m json.tool 2>/dev/null | head -40 \
  || curl -s http://127.0.0.1:11434/api/tags

echo
echo "--- 3. Что бот шлёт — последние строки bot-stderr ---"
STDERR="$BOT_DIR/logs/bot-stderr.log"
if [ -f "$STDERR" ]; then
    echo "Файл: $STDERR ($(wc -l < "$STDERR") строк)"
    echo "Последние 40 строк:"
    tail -40 "$STDERR"
else
    echo "[!] $STDERR не существует"
fi

echo
echo "--- 4. journalctl бота — последние 50 строк ---"
journalctl --user -u "$BOT_SERVICE" -n 50 --no-pager 2>&1 | tail -50

echo
echo "--- 5. Прямой curl /api/chat с минимальным payload ---"
echo "Запрос: gemma3:12b, один user message, без options"
RESP=$(curl -s -w "\nHTTP %{http_code}\n" \
    -X POST http://127.0.0.1:11434/api/chat \
    -H "Content-Type: application/json" \
    -d '{"model":"gemma3:12b","messages":[{"role":"user","content":"скажи ok"}],"stream":false}')
echo "$RESP" | head -20

echo
echo "--- 6. Прямой curl /api/chat с options.num_ctx=8192 (как v18 бот) ---"
RESP=$(curl -s -w "\nHTTP %{http_code}\n" \
    -X POST http://127.0.0.1:11434/api/chat \
    -H "Content-Type: application/json" \
    -d '{"model":"gemma3:12b","messages":[{"role":"user","content":"скажи ok"}],"stream":false,"options":{"num_ctx":8192}}')
echo "$RESP" | head -20

echo
echo "--- 7. Тот же curl но к qwen2.5:7b-instruct (router fallback) ---"
RESP=$(curl -s -w "\nHTTP %{http_code}\n" \
    -X POST http://127.0.0.1:11434/api/chat \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen2.5:7b-instruct","messages":[{"role":"user","content":"скажи ok"}],"stream":false}')
echo "$RESP" | head -20

echo
echo "--- 8. journalctl ollama — последние 30 строк (с этими curl запросами) ---"
sudo journalctl -u ollama.service -n 30 --no-pager 2>&1 | tail -30

echo
echo "===================================================================="
echo "  ГОТОВО. Лог: $LOG"
echo "===================================================================="
