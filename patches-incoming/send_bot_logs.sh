#!/bin/bash

# send_bot_logs.sh — Скрипт для отправки логов диагностики в Телеграм
# Он поможет понять, почему бот виснет, не запуская при этом самого бота.

TARGET_DIR="/home/linuxserver/ai-assistant"

echo "=== СБОР ЛОГОВ ДЛЯ ТЕЛЕГРАМ ==="

# 1. Поиск папки и .env
if [ ! -d "$TARGET_DIR" ]; then
    TARGET_DIR=$(find $(pwd) -name "ai-assistant" -type d -print -quit)
fi

if [ ! -f "$TARGET_DIR/.env" ]; then
    echo "[ОШИБКА] Файл .env не найден. Не могу узнать токен."
    exit 1
fi

# Читаем токен и ID админа
TOKEN=$(grep "^BOT_TOKEN=" "$TARGET_DIR/.env" | cut -d= -f2 | tr -d '\r' | tr -d '"' | tr -d "'")
ADMIN_ID=$(grep "^ADMIN_USER_IDS=" "$TARGET_DIR/.env" | cut -d= -f2 | cut -d, -f1 | tr -d '\r' | tr -d '"' | tr -d "'")

if [ -z "$TOKEN" ] || [ -z "$ADMIN_ID" ]; then
    echo "[ОШИБКА] Не удалось прочитать токен или ID админа из .env"
    exit 1
fi

# 2. Собираем информацию
LOG_FILE="$TARGET_DIR/logs/bot-stderr.log"
BOT_LOG="$TARGET_DIR/logs/bot.log"

REPORT="--- DIAGNOSTIC REPORT ---
Date: $(date)
Target: $TARGET_DIR
--- Last 20 lines of STDERR ---
$(tail -n 20 "$LOG_FILE" 2>/dev/null || echo "File not found")
--- Last 20 lines of BOT LOG ---
$(tail -n 20 "$BOT_LOG" 2>/dev/null || echo "File not found")
--- Processes ---
$(ps aux | grep -E 'python|ollama' | grep -v 'grep' | head -n 5)"

# 3. Отправка в Телеграм через curl
echo "Отправляю отчет в Телеграм (ID: $ADMIN_ID)..."

curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
    -d "chat_id=$ADMIN_ID" \
    -d "text=$REPORT" \
    -d "parse_mode=HTML" > /dev/null

if [ $? -eq 0 ]; then
    echo "[OK] Отчет отправлен. Проверь чат с ботом."
else
    echo "[ОШИБКА] Не удалось отправить сообщение."
fi
