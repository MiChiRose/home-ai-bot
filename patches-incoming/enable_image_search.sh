#!/bin/bash

# enable_image_search.sh — Удаление блокировки поиска картинок
# Вырезает старый кусок кода, который мешал боту искать фото жирафов.

TARGET_DIR="/home/linuxserver/ai-assistant"
echo "=== АКТИВАЦИЯ ПОИСКА КАРТИНОК ==="

# 1. Поиск папки
if [ ! -d "$TARGET_DIR" ]; then
    TARGET_DIR=$(find $(pwd) -name "ai-assistant" -type d -print -quit)
fi

# 2. Удаление блока-блокировщика через Python
echo "[1/2] Удаление назойливого сообщения про удаление генерации..."

python3 <<EOF
import sys
from pathlib import Path
import re

path = Path("$TARGET_DIR/bot/bot.py")
if not path.exists():
    print("Файл bot.py не найден!")
    sys.exit(1)

content = path.read_text(encoding="utf-8")

# Удаляем весь блок v6 (блокировка картинок)
# Ищем паттерн от начала комментария про v6 до return в конце блока
pattern = re.compile(r'# v6 \(2026-05-18\) — IMAGE_GEN_REMOVED:.*?return', re.DOTALL)

if pattern.search(content):
    content = pattern.sub('', content)
    # Исправляем возможные двойные пустые строки после удаления
    content = content.replace('\n\n\n\n', '\n\n')
    path.write_text(content, encoding="utf-8")
    print("[OK] Блокировка вырезана. Теперь поиск картинок заработает.")
else:
    print("[!] Блок блокировки не найден (возможно, он уже удален или изменен).")
EOF

# 3. Перезапуск для применения
pkill -9 -f "bot.py"

echo ""
echo "=== ГОТОВО! ==="
echo "Теперь попробуй написать боту: 'Найди фото жирафа'."
echo "Запускай бота: ./restart_bot.sh"
