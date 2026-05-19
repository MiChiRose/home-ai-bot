#!/bin/bash

# check_token.sh — Проверка валидности токена в Telegram
# Этот скрипт просто спрашивает Telegram: "Этот токен правильный?"

TARGET_DIR="/home/linuxserver/ai-assistant"

if [ ! -f "$TARGET_DIR/.env" ]; then
    echo "[ОШИБКА] Файл .env не найден в $TARGET_DIR"
    exit 1
fi

# Извлекаем токен из .env (убираем лишние пробелы и кавычки)
TOKEN=$(grep "^BOT_TOKEN=" "$TARGET_DIR/.env" | cut -d= -f2 | tr -d '\r\t "' | tr -d "'")

if [ -z "$TOKEN" ]; then
    echo "[ОШИБКА] BOT_TOKEN пуст в файле .env"
    exit 1
fi

echo "--- ПРОВЕРКА ТОКЕНА (первые 10 знаков: ${TOKEN:0:10}...) ---"

# Делаем запрос к Telegram API
RESPONSE=$(curl -s "https://api.telegram.org/bot$TOKEN/getMe")

# Проверяем ответ
if echo "$RESPONSE" | grep -q '"ok":true'; then
    echo "[ВЕРНО] ✅ Telegram подтвердил токен!"
    echo "Бот: $(echo $RESPONSE | python3 -c "import sys, json; print(json.load(sys.stdin)['result']['username'])")"
else
    echo "[ОШИБКА] ❌ Telegram НЕ ПРИНЯЛ токен."
    echo "Ответ сервера: $RESPONSE"
    echo ""
    echo "ЧТО ДЕЛАТЬ:"
    echo "1. Зайди в @BotFather и получи свежий токен через /token."
    echo "2. Убедись, что в .env строка выглядит так: BOT_TOKEN=твой_токен"
    echo "3. Убедись, что в начале строки нет знака #"
fi
