#!/bin/bash
TARGET_DIR="/home/linuxserver/ai-assistant"
TOKEN=$(grep "^BOT_TOKEN=" "$TARGET_DIR/.env" | cut -d= -f2 | tr -d '\r\t "')
ADMIN=$(grep "^ADMIN_USER_IDS=" "$TARGET_DIR/.env" | cut -d= -f2 | cut -d, -f1 | tr -d '\r\t "')
LOGS=$(tail -n 30 "$TARGET_DIR/logs/bot-stderr.log" 2>/dev/null)
curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$ADMIN" -d "text=LOGS:
$LOGS" > /dev/null
echo "[OK] Логи ушли в ТГ."
