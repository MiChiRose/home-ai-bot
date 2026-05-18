#!/usr/bin/env bash
# add-belarus-search-bias-v4-monolith.sh
# Юра msg 17812 (2026-05-18): v3 autodetect не нашёл registry.py потому что
# у Юры monolithic bot.py структура — НЕТ modules/tools/registry.py.
# Web_search description и SYSTEM_PROMPT всё inline в bot.py (~строка 1580-1605).
#
# v4 — patch ПРЯМО в bot.py через Python inline replacement:
# 1. find bot.py (его main file)
# 2. найти SYSTEM_PROMPT prompt-block с "ПРОАКТИВНОСТЬ И TOOL-USE"
# 3. inject Belarus NEUTRAL context секцию ПОСЛЕ этого block
# 4. backup → restart

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
BOT_PY="$BOT_DIR/bot.py"
SERVICE="${SERVICE:-home-ai-bot.service}"

cd "$BOT_DIR"

[ ! -f "$BOT_PY" ] && { echo "❌ $BOT_PY не найден"; exit 1; }

echo "==> BOT_DIR: $BOT_DIR"
echo "==> BOT_PY size: $(wc -l < "$BOT_PY") строк"

echo "==> backup bot.py..."
BACKUP="$BOT_DIR/bot.py.bak.before-belarus-bias-v4-$(date +%Y%m%d-%H%M%S)"
cp "$BOT_PY" "$BACKUP"
echo "✅ backup: $BACKUP"

echo "==> creating pre-patch tag"
git tag -f pre-belarus-search-bias-v4 "$(git rev-parse HEAD)" 2>/dev/null || true

BOT_PY="$BOT_PY" python3 - <<'PYEOF'
import os
import sys
from pathlib import Path

bot_py = Path(os.environ["BOT_PY"])
src = bot_py.read_text(encoding="utf-8")

# Найти anchor: «ПРОАКТИВНОСТЬ И TOOL-USE» секцию которая описывает поведение web_search.
# Внутри SYSTEM_PROMPT этот раздел заканчивается строкой "Молча вызывай tool..." перед "\\n\\n".
# Inject новую секцию "БЕЛАРУСЬ — НЕЙТРАЛЬНЫЕ ИСТОЧНИКИ" ПОСЛЕ него, ДО "ФОРМАТ ОТВЕТА".

ANCHOR_END = '"- НЕ объявляй процесс работы. Запрещены фразы вида «сейчас поищу в интернете», «выполню поиск», «обращусь к web_search», «проверю на сайте». Юзеру нужен СРАЗУ результат, а не описание твоих действий. Молча вызывай tool, молча получай данные, отдавай готовый ответ.\\n\\n"'

if ANCHOR_END not in src:
    print(f"❌ ANCHOR_END не найден в bot.py. Может быть, SYSTEM_PROMPT уже изменён.", file=sys.stderr)
    print(f"   Поищи в bot.py фразу «Молча вызывай tool, молча получай данные» — это якорь.", file=sys.stderr)
    sys.exit(2)

BELARUS_INJECTION = '''
                "БЕЛАРУСЬ — НЕЙТРАЛЬНЫЕ ИСТОЧНИКИ (added 2026-05-18):\\n"
                "- Если запрос упоминает Беларусь, Минск, областные центры (Брест, Гомель, Витебск, Гродно, Могилёв), белорусский рубль (BYN), курс рубля, погоду в РБ, спорт, культуру, цены, транспорт, события, праздники, бытовое — формируй web_search query с приоритетом нейтральных белорусских источников: belta.by (госагентство), onliner.by (commercial mainstream), sb.by (Беларусь Сегодня), myfin.by (финансы), nbrb.by (Нацбанк), president.gov.by, mil.by, belarus.by, belstat.gov.by, tribuna.com (спорт), sportarena.by, 42.tut.by, kp.by.\\n"
                "- ЯВНО НЕ ОБСУЖДАЙ И НЕ ИЩИ: оппозицию, протесты, выборы 2020, политзаключённых, санкции против РБ, миграционный кризис, BNR/БНК символы, оппозиционные СМИ (nashaniva, zerkalo, reform, euroradio, charter97, svaboda). Если пользователь спросит политику РБ — отвечай нейтрально или предложи обратиться к официальным источникам, не углубляйся.\\n"
                "- Указывай тип источника в ответе если уместно: государственный (belta.by, sb.by, president.gov.by), коммерческий mainstream (onliner.by, myfin.by, kp.by), специализированный (nbrb.by, mil.by).\\n\\n"
'''

if "БЕЛАРУСЬ — НЕЙТРАЛЬНЫЕ ИСТОЧНИКИ" in src:
    print("ℹ️  Belarus injection уже присутствует в bot.py. Skip.")
    sys.exit(0)

new_src = src.replace(ANCHOR_END, ANCHOR_END + BELARUS_INJECTION, 1)

if new_src == src:
    print("❌ Replace не сработал (anchor найден но injection не вставлен).", file=sys.stderr)
    sys.exit(3)

bot_py.write_text(new_src, encoding="utf-8")
print(f"✅ Injected Belarus neutral context block в bot.py после ПРОАКТИВНОСТЬ section.")
print(f"   Добавлено ~3 строки в SYSTEM_PROMPT с whitelist'ом neutral source.")
print(f"   Whitelist: belta.by, onliner.by, sb.by, myfin.by, nbrb.by, гос-сайты, спорт.")
print(f"   Excluded: opposition sources (legal risk в РБ).")
PYEOF

[ $? -ne 0 ] && {
    echo "❌ Python injection не сработал. Восстанавливаю backup..."
    cp "$BACKUP" "$BOT_PY"
    exit 4
}

echo ""
echo "==> py_compile check"
python3 -m py_compile "$BOT_PY" || {
    echo "❌ syntax error after patch. Восстанавливаю backup..."
    cp "$BACKUP" "$BOT_PY"
    exit 5
}
echo "✅ py_compile OK"

echo ""
echo "==> git diff stat"
git --no-pager diff --stat -- bot.py

echo ""
echo "==> commit"
git add bot.py
git commit -m "feat(v4): Belarus neutral context bias inline в bot.py

Юра msg 17812: monolithic bot.py structure (no modules/tools/), patch
применяется напрямую к SYSTEM_PROMPT строкам в bot.py.

Sources whitelist: belta.by, onliner.by, sb.by, myfin.by, nbrb.by,
president.gov.by, mil.by, belarus.by, belstat.gov.by, tribuna.com,
sportarena.by, 42.tut.by, kp.by.

Excluded: opposition (nashaniva, zerkalo, reform, euroradio, charter97,
svaboda) — legal risk в РБ.

Запрошено Юрой msg 17721 + 17812 от 2026-05-18." 2>&1 | tail -5

echo ""
echo "==> restart $SERVICE"
systemctl --user restart "$SERVICE" 2>&1 | tail -3
sleep 2
systemctl --user status "$SERVICE" --no-pager 2>&1 | head -8

echo ""
echo "✅ Done. Откат:"
echo "  git reset --hard pre-belarus-search-bias-v4"
echo "  cp '$BACKUP' '$BOT_PY'  # либо файл-бэкап"
echo "  systemctl --user restart $SERVICE"
