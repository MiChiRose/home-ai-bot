#!/bin/bash

# final_fix_qwen.sh — Возврат на Qwen + полная зачистка
# Этот скрипт ставит быструю модель Qwen, но оставляет наши строгие правила поиска.

TARGET_DIR="/home/linuxserver/ai-assistant"

echo "=== ФИНАЛЬНЫЙ ФИКС: ВОЗВРАТ НА QWEN ==="

# 1. Поиск папки
if [ ! -d "$TARGET_DIR" ]; then
    TARGET_DIR=$(find $(pwd) -name "ai-assistant" -type d -print -quit)
fi

# 2. Обновление модели в .env (ставим qwen обратно)
echo "[1/5] Настройка Qwen2.5 (быстрая модель)..."
sed -i 's/MODEL_ROUTER=.*/MODEL_ROUTER=qwen2.5:7b-instruct/' "$TARGET_DIR/.env"
sed -i 's/MODEL_INSTRUCT=.*/MODEL_INSTRUCT=qwen2.5:7b-instruct/' "$TARGET_DIR/.env"
sed -i 's/TOOLS_MODEL=.*/TOOLS_MODEL=qwen2.5:7b-instruct/' "$TARGET_DIR/.env"
sed -i 's/OLLAMA_MODEL=.*/OLLAMA_MODEL=qwen2.5:7b-instruct/' "$TARGET_DIR/.env"

# 3. Полное удаление конфликтующей службы
echo "[2/5] Удаление системной службы-невидимки..."
sudo systemctl stop home-ai-bot.service 2>/dev/null
sudo systemctl disable home-ai-bot.service 2>/dev/null
sudo rm /etc/systemd/system/home-ai-bot.service 2>/dev/null
sudo systemctl daemon-reload

# 4. Перезапуск Ollama (чтобы освободить VRAM)
echo "[3/5] Перезапуск Ollama..."
sudo systemctl restart ollama
sleep 3

# 5. Очистка процессов
echo "[4/5] Очистка процессов..."
sudo pkill -9 -f "bot.py"
sudo pkill -9 -f "ai-assistant"

# 6. Запуск
echo "[5/5] ЗАПУСК БОТА (QWEN)..."
cd "$TARGET_DIR"
source .venv/bin/activate
python3 bot/bot.py
