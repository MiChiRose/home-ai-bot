#!/bin/bash

# clean_qwen_fix.sh — Только исправление конфига и очистка (БЕЗ ЗАПУСКА)
# Этот скрипт ставит быструю модель Qwen и удаляет службу.

TARGET_DIR="/home/linuxserver/ai-assistant"

echo "=== ЧИСТКА И НАСТРОЙКА QWEN ==="

# 1. Поиск папки
if [ ! -d "$TARGET_DIR" ]; then
    TARGET_DIR=$(find $(pwd) -name "ai-assistant" -type d -print -quit)
fi

if [ -z "$TARGET_DIR" ]; then
    echo "[ОШИБКА] Не удалось найти папку ai-assistant."
    exit 1
fi

# 2. Обновление модели в .env
echo "[1/4] Настройка Qwen2.5..."
sed -i 's/MODEL_ROUTER=.*/MODEL_ROUTER=qwen2.5:7b-instruct/' "$TARGET_DIR/.env"
sed -i 's/MODEL_INSTRUCT=.*/MODEL_INSTRUCT=qwen2.5:7b-instruct/' "$TARGET_DIR/.env"
sed -i 's/TOOLS_MODEL=.*/TOOLS_MODEL=qwen2.5:7b-instruct/' "$TARGET_DIR/.env"
sed -i 's/OLLAMA_MODEL=.*/OLLAMA_MODEL=qwen2.5:7b-instruct/' "$TARGET_DIR/.env"

# 3. Полное удаление конфликтующей службы
echo "[2/4] Удаление системной службы..."
sudo systemctl stop home-ai-bot.service 2>/dev/null
sudo systemctl disable home-ai-bot.service 2>/dev/null
sudo rm /etc/systemd/system/home-ai-bot.service 2>/dev/null
sudo systemctl daemon-reload

# 4. Перезапуск Ollama
echo "[3/4] Перезапуск Ollama..."
sudo systemctl restart ollama
sleep 2

# 5. Очистка процессов
echo "[4/4] Очистка фоновых процессов Python..."
sudo pkill -9 -f "bot.py"
sudo pkill -9 -f "ai-assistant"

echo ""
echo "=== ГОТОВО! БОТ НЕ ЗАПУЩЕН ==="
echo "Конфигурация исправлена, память очищена."
echo "Теперь запусти его сам:"
echo "cd $TARGET_DIR && source .venv/bin/activate && python3 bot/bot.py"
