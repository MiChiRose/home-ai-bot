#!/usr/bin/env bash
# Root cause 400 у Юры: bot.py:408 использует `re.compile(...)` но `import re`
# либо отсутствует, либо был случайно удалён в одной из вчерашних правок.
# В bot-stderr видно повторяющийся NameError: name 're' is not defined.
#
# Скрипт:
#   1. Проверяет есть ли import re в первых 30 строках bot.py
#   2. Если нет — добавляет в backup + патчит
#   3. Перезапускает бот + проверяет логи
#
# Запуск БЕЗ sudo:  bash ./fix-bot-import-re.sh
# Лог в ~/Documents/

set -u
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$HOME/Documents/bot-fix-re-$STAMP.log"
BOT_DIR="$HOME/ai-assistant"
BOT_PY="$BOT_DIR/bot/bot.py"
BOT_SERVICE="home-ai-bot.service"

mkdir -p "$HOME/Documents"
exec > >(tee -a "$LOG") 2>&1

echo "===================================================================="
echo "  Fix: добавить 'import re' в bot.py если отсутствует"
echo "  $(date -Iseconds) — лог: $LOG"
echo "===================================================================="

echo
echo "--- 1. Проверка bot.py:408 (что там реально) ---"
sed -n '405,412p' "$BOT_PY" 2>/dev/null

echo
echo "--- 2. Есть ли 'import re' в первых 60 строках? ---"
if head -60 "$BOT_PY" | grep -qE "^import re($|\s|,)|^from re " ; then
    echo "[+] import re НАЙДЕН в первых 60 строках:"
    head -60 "$BOT_PY" | grep -nE "^import re|^from re " | head -3
    echo
    echo "Тогда NameError странный. Проверю весь файл:"
    grep -nE "^import re($|\s|,)|^from re " "$BOT_PY" | head -3
    echo
    echo "Если import re ниже строки 408 — это и есть баг (используется до import)."
else
    echo "[!] import re ОТСУТСТВУЕТ — это и есть root cause NameError."
fi

echo
echo "--- 3. Бэкап + патч (только если import re отсутствует в первых 60 строках) ---"
if ! head -60 "$BOT_PY" | grep -qE "^import re($|\s|,)|^from re " ; then
    BACKUP="$BOT_PY.bak-no-re-$STAMP"
    cp -a "$BOT_PY" "$BACKUP"
    echo "[+] backup: $BACKUP"

    # Найти строку существующего import (любого), вставить 'import re' над ней.
    # Безопасный паттерн: первая строка начинающаяся с 'import ' или 'from '.
    LINE=$(grep -nE "^import |^from " "$BOT_PY" | head -1 | cut -d: -f1)
    if [ -z "$LINE" ]; then
        echo "[!] не нашёл ни одного import — патч abort. Сообщи Эвану."
        exit 2
    fi
    echo "Вставляю 'import re' перед строкой $LINE"
    sed -i.bak2 "${LINE}i import re" "$BOT_PY"
    rm -f "${BOT_PY}.bak2"
    head -$(($LINE+3)) "$BOT_PY" | tail -5
fi

echo
echo "--- 4. Syntax check (py_compile) ---"
"$BOT_DIR/.venv/bin/python" -m py_compile "$BOT_PY" && echo "[+] compile OK" || echo "[!] compile FAIL"

echo
echo "--- 5. Reset failure counter + restart ---"
systemctl --user reset-failed "$BOT_SERVICE" 2>&1 || true
systemctl --user restart "$BOT_SERVICE"
sleep 4

echo
echo "--- 6. Статус ---"
systemctl --user is-active "$BOT_SERVICE" && echo "[+] active" || echo "[!] НЕ active"
echo
echo "--- 7. Последние 20 строк лога ---"
journalctl --user -u "$BOT_SERVICE" -n 20 --no-pager 2>&1 | tail -20

echo
echo "--- 8. Bot stderr — что добавилось после restart ---"
tail -10 "$BOT_DIR/logs/bot-stderr.log" 2>/dev/null

echo
echo "===================================================================="
echo "  ГОТОВО. Лог: $LOG"
echo "  Если active без NameError — попробуй написать боту, должен ответить."
echo "===================================================================="
