#!/bin/bash

# send_debug_report.sh — Максимально подробный отчет в Telegram
# Поможет понять, почему бот пишет "попробую еще раз" и где он спотыкается.

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
LOG_ERR=$(tail -n 50 "$TARGET_DIR/logs/bot-stderr.log" 2>/dev/null | sed 's/<[^>]*>//g')
LOG_MAIN=$(tail -n 20 "$TARGET_DIR/logs/bot.log" 2>/dev/null | sed 's/<[^>]*>//g')
PS_INFO=$(ps aux | grep -E "python|bot.py" | grep -v "grep" | head -n 3)

# Формируем текст (экранируем спецсимволы для HTML если нужно, но тут просто текст)
MESSAGE="🛠 **DEBUG REPORT** 🛠

--- 🖥 ПРОЦЕССЫ: ---
$PS_INFO

--- ❌ ОШИБКИ (Last 50 lines): ---
$LOG_ERR

--- 📝 ЛОГ БОТА (Last 20 lines): ---
$LOG_MAIN"

# 3. Отправка (режем на части если слишком длинный)
echo "Отправляю подробный отчет в Telegram..."

# Telegram имеет лимит 4096 символов. Отправим файл, если текст большой.
if [ ${#MESSAGE} -gt 4000 ]; then
    echo "$MESSAGE" > /tmp/bot_debug.txt
    curl -s -v -F "chat_id=$ADMIN" -F "document=@/tmp/bot_debug.txt" "https://api.telegram.org/bot$TOKEN/sendDocument" > /dev/null
else
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
        -d "chat_id=$ADMIN" \
        -d "text=$MESSAGE" > /dev/null
fi

if [ $? -eq 0 ]; then
    echo "[OK] Отчет успешно отправлен!"
else
    echo "[ОШИБКА] Не удалось отправить отчет."
fi
