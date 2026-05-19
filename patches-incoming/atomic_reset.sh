#!/bin/bash

# atomic_reset.sh — Ядерный перезапуск бота (Финальное решение)
# Решает две проблемы: 
# 1. Telegram Conflict (убивает скрытую службу)
# 2. Зависание (очищает очередь и перезапускает Ollama)

echo "=== АТОМАРНЫЙ ПЕРЕЗАПУСК БОТА ==="

# 1. Жесткая остановка службы-невидимки
echo "[1/5] Уничтожение системной службы..."
sudo systemctl stop home-ai-bot.service 2>/dev/null
sudo systemctl disable home-ai-bot.service 2>/dev/null
sudo rm /etc/systemd/system/home-ai-bot.service 2>/dev/null
sudo systemctl daemon-reload

# 2. Очистка памяти
echo "[2/5] Очистка процессов Python..."
sudo pkill -9 -f "bot.py"
sudo pkill -9 -f "ai-assistant"

# 3. Перезапуск Ollama (чтобы снять зависшие модели)
echo "[3/5] Перезапуск Ollama (нужен пароль)..."
sudo systemctl restart ollama
sleep 3

# 4. Проверка и запуск
echo "[4/5] Подготовка к чистому запуску..."
TARGET_DIR="/home/linuxserver/ai-assistant"
if [ ! -d "$TARGET_DIR" ]; then
    TARGET_DIR=$(find $(pwd) -name "ai-assistant" -type d -print -quit)
fi

cd "$TARGET_DIR"
source .venv/bin/activate

# 5. Запуск
echo "[5/5] БОТ ЗАПУСКАЕТСЯ..."
echo "--- ВНИМАНИЕ: Сначала бот может 'прогреваться' до 1 минуты ---"
python3 bot/bot.py
