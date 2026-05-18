#!/usr/bin/env bash
# v10 — Юра msg 17940: бот hallucinated курс 2.40 для выходных (реальный был 2.77-2.80).
#
# Root causes:
# 1) v5 _CURRENCY_INTENT_RE требует слово «доллар/евро/USD/...» — если юзер
#    спрашивает «какой курс был на выходных» БЕЗ слова валюты, intercept
#    не срабатывает → LLM сам отвечает → hallucinated число из памяти.
# 2) В SYSTEM_PROMPT нет явного запрета на hallucinated финансовых данных.
#
# Fix:
# - Расширить _CURRENCY_INTENT_RE: «курс» без валюты → intercept'ить
#   (default USD в _detect_currency_token уже есть)
# - SYSTEM_PROMPT: ЗАПРЕТ на конкретные числа без tool/web_search.

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
BOT_PY="$BOT_DIR/bot.py"
SERVICE="${SERVICE:-home-ai-bot.service}"

cd "$BOT_DIR"
[ ! -f "$BOT_PY" ] && { echo "❌ $BOT_PY не найден"; exit 1; }

BACKUP="$BOT_DIR/bot.py.bak.before-tools-v10-$(date +%Y%m%d-%H%M%S)"
cp "$BOT_PY" "$BACKUP"

git tag -f pre-tools-v10 "$(git rev-parse HEAD)" 2>/dev/null || true

BOT_PY="$BOT_PY" python3 - <<'PYEOF'
import os, re, sys
from pathlib import Path

bot_py = Path(os.environ["BOT_PY"])
src = bot_py.read_text(encoding="utf-8")

if "ANTI_HALLUCINATION_CURRENCY v10" in src:
    print("ℹ️  v10 уже применён. Skip.")
    sys.exit(0)

# === 1. Расширить _CURRENCY_INTENT_RE — добавить третью alternative: bare «курс» ===
OLD_RE_LINE = '''    r"\\bкурс\\b.*\\b(доллар|евро|рубл|usd|eur|rub|pln|gbp|cny|uah)|"
    r"\\b(доллар|евро|usd|eur)\\b.*\\bкурс\\b",'''

NEW_RE_LINE = '''    r"\\bкурс\\b.*\\b(доллар|евро|рубл|usd|eur|rub|pln|gbp|cny|uah)|"
    r"\\b(доллар|евро|usd|eur)\\b.*\\bкурс\\b|"
    r"\\b(какой|какая|какой\\s+был|какой\\s+стал)\\s+курс\\b|"
    r"\\bкурс\\s+(на|был|за|сегодня|вчера|на выходных|в пятницу|в субботу|в понедельник|в воскресенье)\\b",  # v10 ANTI_HALLUCINATION_CURRENCY broader currency intent match'''

if OLD_RE_LINE in src:
    src = src.replace(OLD_RE_LINE, NEW_RE_LINE)
    print("✅ _CURRENCY_INTENT_RE расширен (bare «курс» теперь intercept'ится)")
else:
    print("⚠️  _CURRENCY_INTENT_RE старая сигнатура не найдена — manual review", file=sys.stderr)

# === 2. SYSTEM_PROMPT: anti-hallucination rule для финансов ===
ANTI_HALLUCINATION_RULE = '''                "АНТИ-ГАЛЛЮЦИНАЦИЯ ФИНАНСОВЫХ ДАННЫХ (v10 ANTI_HALLUCINATION_CURRENCY 2026-05-18):\\n"
                "- ЗАПРЕЩЕНО называть конкретные числовые значения курсов валют, цен, котировок, биржевых данных из памяти. Если ты не вызвал tool или web_search и не получил подтверждённое значение — ОТКАЖИСЬ давать число.\\n"
                "- Запрещены формулировки «курс был X», «цена около Y» если данные не получены через tool/search в этой сессии.\\n"
                "- Корректный ответ при отсутствии tool результата: «не могу проверить без актуальных данных, попробуй переформулировать или укажи дату».\\n"
                "- Это критично — пользователь принимает решения на основе цифр, hallucinated значения = реальный ущерб.\\n\\n"
'''

# Anchor — после image-gen passive rule (v8) или после small-talk (v5b)
anchors = [
    '"ГЕНЕРАЦИЯ КАРТИНОК — ПАССИВНОЕ ПРАВИЛО (v8',
    '"- web_search вызывай ТОЛЬКО когда юзер реально просит факт',
]
inserted = False
for anchor in anchors:
    pos = src.find(anchor)
    if pos < 0:
        continue
    # Find end of multi-line string block — closing `\\n\\n"\n`
    line_end = src.find('\\n\\n"\n', pos)
    if line_end < 0:
        continue
    insert_pos = line_end + len('\\n\\n"\n')
    src = src[:insert_pos] + ANTI_HALLUCINATION_RULE + src[insert_pos:]
    print(f"✅ Anti-hallucination rule injected после {anchor[:40]!r}")
    inserted = True
    break

if not inserted:
    print("⚠️  Anti-hallucination rule НЕ injected — anchor не найден", file=sys.stderr)

bot_py.write_text(src, encoding="utf-8")
print(f"\n✅ bot.py updated. Size: {len(src)} chars.")
PYEOF

[ $? -ne 0 ] && { cp "$BACKUP" "$BOT_PY"; exit 4; }
python3 -m py_compile "$BOT_PY" || { cp "$BACKUP" "$BOT_PY"; exit 5; }
echo "✅ py_compile OK"

git add bot.py
git commit -m "fix(v10): анти-галлюцинация финансовых данных

Юра msg 17940 (2026-05-18): бот выдал курс 2.40 на выходные (реальный
2.77-2.80) — hallucinated значение из памяти, intercept не сработал.

Root cause:
- _CURRENCY_INTENT_RE требовал явное слово валюты — «какой курс на
  выходных» не intercept'ился → LLM отвечал из памяти, выдумывал число.
- В SYSTEM_PROMPT не было явного запрета на hallucinated финансы.

Fix:
1. Расширил regex: bare «курс» и «какой курс был/стал/на/за/в пятницу/...»
   теперь intercept'ятся → NBRB API (с v7 date parsing).
2. SYSTEM_PROMPT: явный запрет называть числа курсов/цен/котировок
   без вызова tool или web_search в текущей сессии.

Зависимость: лучше работает вместе с v7 (date parsing).

Backup tag: pre-tools-v10. Откат: git reset --hard pre-tools-v10." 2>&1 | tail -5

systemctl --user restart "$SERVICE" 2>&1 | tail -3
sleep 2

echo ""
echo "✅ v10 applied. Tests:"
echo "  «какой курс был на выходных» → intercept → NBRB на субботу"
echo "  «курс доллара» → NBRB сегодня"
echo "  «курс на 15.05» → NBRB на 2026-05-15"
echo "  «расскажи про bitcoin» → НЕ intercept (нет слова курс), LLM"
echo ""
echo "Откат: git reset --hard pre-tools-v10"
