#!/bin/bash

# send_bot_logs_v2.sh — Отправка логов в Telegram
# Работает даже если бот завис.

TARGET_DIR="/home/linuxserver/ai-assistant"

# 1. Читаем конфиг
if [ ! -f "$TARGET_DIR/.env" ]; then
    echo "[ОШИБКА] Файл .env не найден!"
    exit 1
fi

TOKEN=$(grep "^BOT_TOKEN=" "$TARGET_DIR/.env" | cut -d= -f2 | tr -d '\r\t "' | tr -d "'")
ADMIN=$(grep "^ADMIN_USER_IDS=" "$TARGET_DIR/.env" | cut -d= -f2 | cut -d, -f1 | tr -d '\r\t "' | tr -d "'")

if [ -z "$TOKEN" ] || [ -z "$ADMIN" ]; then
    echo "[ОШИБКА] Не удалось прочитать данные из .env"
    exit 1
fi

# 2. Собираем логи
LOG_ERR=$(tail -n 30 "$TARGET_DIR/logs/bot-stderr.log" 2>/dev/null)
LOG_MAIN=$(tail -n 10 "$TARGET_DIR/logs/bot.log" 2>/dev/null)

MESSAGE="--- 🤖 ОТЧЕТ ПО ЛОГАМ ---
Дата: $(date)

--- STDERR (Ошибки): ---
$LOG_ERR

--- BOT LOG (Последнее): ---
$LOG_MAIN"

# 3. Отправка
echo "Отправляю логи админу $ADMIN..."

curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
    -d "chat_id=$ADMIN" \
    -d "text=$MESSAGE" > /dev/null

if [ $? -eq 0 ]; then
    echo "[OK] Логи успешно отправлены в Telegram!"
else
    echo "[ОШИБКА] Не удалось отправить сообщение. Проверь интернет и токен."
fi
