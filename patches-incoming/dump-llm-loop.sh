#!/usr/bin/env bash
# Дамп tools/llm_loop.py (50 строк вокруг падающего line 64) + grep на payload params.
# Это даст мне точно увидеть какой payload бот шлёт в Ollama.
#
# Запуск: bash ./dump-llm-loop.sh

set -u
BOT_DIR="$HOME/ai-assistant"
LOOP="$BOT_DIR/tools/llm_loop.py"
OUT="$HOME/Documents/llm-loop-dump-$(date +%Y%m%d-%H%M%S).txt"

mkdir -p "$HOME/Documents"

if [ ! -f "$LOOP" ]; then
    echo "[!] $LOOP не существует. Поищу llm_loop в проекте..."
    find "$BOT_DIR" -name "llm_loop*.py" -not -path "*__pycache__*" 2>/dev/null | head
    exit 1
fi

{
    echo "=== llm_loop.py dump $(date -Iseconds) ==="
    echo "Path: $LOOP"
    echo "Size: $(wc -l < "$LOOP") строк"
    echo
    echo "=== Полный файл (до 300 строк, должно хватить) ==="
    head -300 "$LOOP"
    echo
    echo "=== Grep: payload / model / messages / tools / format / options ==="
    grep -n -E "model|messages|tools|format|options|num_ctx|stream|api/chat|post|json=" "$LOOP" | head -50
    echo
    echo "=== строки 50-100 (вокруг падающего line 64) ==="
    sed -n '50,100p' "$LOOP"
} | tee "$OUT"

echo
echo "Сохранено: $OUT"
