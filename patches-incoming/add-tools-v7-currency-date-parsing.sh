#!/usr/bin/env bash
# add-tools-v7-currency-date-parsing.sh
# Юра msg 17913 (2026-05-18) — bug: «курс в пятницу» возвращает сегодняшнюю дату.
# Root cause: get_nbrb_rate всегда тянет текущий курс, try_factual_intent_routing
# не парсит relative dates.
#
# Fix:
# 1. get_nbrb_rate(currency, date=None) — если date указана, NBRB API
#    параметр &ondate=YYYY-MM-DD.
# 2. _parse_date_token(text) — детектит:
#    - «вчера» / «позавчера»
#    - «сегодня»
#    - дни недели «в пятницу», «в понедельник» (берёт ближайший прошлый день)
#    - «N.M» / «N.M.YYYY» / «N мая/июня/...»
# 3. try_factual_intent_routing — извлекает date, передаёт в get_nbrb_rate.

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
BOT_PY="$BOT_DIR/bot.py"
SERVICE="${SERVICE:-home-ai-bot.service}"

cd "$BOT_DIR"
[ ! -f "$BOT_PY" ] && { echo "❌ $BOT_PY не найден"; exit 1; }

echo "==> bot.py: $(wc -l < "$BOT_PY") строк"

BACKUP="$BOT_DIR/bot.py.bak.before-tools-v7-$(date +%Y%m%d-%H%M%S)"
cp "$BOT_PY" "$BACKUP"
echo "✅ backup: $BACKUP"

git tag -f pre-tools-v7 "$(git rev-parse HEAD)" 2>/dev/null || true

BOT_PY="$BOT_PY" python3 - <<'PYEOF'
import os, re, sys
from pathlib import Path

bot_py = Path(os.environ["BOT_PY"])
src = bot_py.read_text(encoding="utf-8")

if "DATE_PARSING v7" in src:
    print("ℹ️  v7 уже применён. Skip.")
    sys.exit(0)

# ====================================================================
# 1. Replace get_nbrb_rate signature: add date param
# ====================================================================
OLD_FN = '''def get_nbrb_rate(currency: str = "USD") -> str:
    """Получить официальный курс валюты НБРБ. Возвращает форматированную строку
    без упоминания источника."""
    cur = currency.upper().strip()
    cur_map = {"USD": "USD", "EUR": "EUR", "RUB": "RUB", "RUR": "RUB",
               "PLN": "PLN", "GBP": "GBP", "CNY": "CNY", "UAH": "UAH"}
    cur_code = cur_map.get(cur, cur)
    url = f"https://api.nbrb.by/exrates/rates/{cur_code}?parammode=2"'''

NEW_FN = '''def get_nbrb_rate(currency: str = "USD", date: str | None = None) -> str:
    """Получить официальный курс валюты НБРБ. DATE_PARSING v7 2026-05-18.

    date: optional YYYY-MM-DD. Если None — текущий курс.
    Возвращает форматированную строку без упоминания источника."""
    cur = currency.upper().strip()
    cur_map = {"USD": "USD", "EUR": "EUR", "RUB": "RUB", "RUR": "RUB",
               "PLN": "PLN", "GBP": "GBP", "CNY": "CNY", "UAH": "UAH"}
    cur_code = cur_map.get(cur, cur)
    url = f"https://api.nbrb.by/exrates/rates/{cur_code}?parammode=2"
    if date:
        url += f"&ondate={date}"'''

if OLD_FN in src:
    src = src.replace(OLD_FN, NEW_FN)
    print("✅ get_nbrb_rate signature расширен с date param")
else:
    print("❌ get_nbrb_rate signature не найден", file=sys.stderr)
    sys.exit(2)

# ====================================================================
# 2. Inject _parse_date_token helper перед try_factual_intent_routing
# ====================================================================
DATE_PARSER = '''
def _parse_date_token(text: str) -> str | None:
    """DATE_PARSING v7 2026-05-18.
    Парсит relative/absolute date из user_text.
    Returns YYYY-MM-DD or None если не нашёл."""
    import datetime as _dt
    import re as _re
    text_l = text.lower()
    today = _dt.date.today()

    # «сегодня» → today
    if _re.search(r"\\bсегодня\\b", text_l):
        return today.isoformat()

    # «вчера»
    if _re.search(r"\\bвчера\\b", text_l):
        return (today - _dt.timedelta(days=1)).isoformat()

    # «позавчера»
    if _re.search(r"\\bпозавчера\\b", text_l):
        return (today - _dt.timedelta(days=2)).isoformat()

    # Дни недели — последний прошедший / ближайший
    days = {"понедельник": 0, "вторник": 1, "сред": 2, "четверг": 3,
            "пятниц": 4, "суббот": 5, "воскресень": 6}
    for stem, idx in days.items():
        if stem in text_l:
            # «в пятницу» / «в прошлую пятницу» — последний прошедший этот день
            delta = (today.weekday() - idx) % 7
            if delta == 0:
                delta = 7  # сам сегодняшний день — берём прошлую неделю
            return (today - _dt.timedelta(days=delta)).isoformat()

    # Формат «15.05» / «15.05.2026»
    m = _re.search(r"\\b(\\d{1,2})\\.(\\d{1,2})(?:\\.(\\d{4}))?\\b", text)
    if m:
        d, mo, y = m.groups()
        y = int(y) if y else today.year
        try:
            return _dt.date(y, int(mo), int(d)).isoformat()
        except ValueError:
            pass

    # «15 мая» / «18 мая 2026»
    months = {"январ": 1, "феврал": 2, "март": 3, "апрел": 4, "ма": 5,
              "июн": 6, "июл": 7, "август": 8, "сентябр": 9, "октябр": 10,
              "ноябр": 11, "декабр": 12}
    m = _re.search(r"\\b(\\d{1,2})\\s+([а-я]{3,})(?:\\s+(\\d{4}))?\\b", text_l)
    if m:
        d, mname, y = m.groups()
        for stem, idx in months.items():
            if mname.startswith(stem):
                y = int(y) if y else today.year
                try:
                    return _dt.date(y, idx, int(d)).isoformat()
                except ValueError:
                    pass
                break

    return None


'''

ANCHOR_TFIR = "def try_factual_intent_routing(user_text: str):"
if "_parse_date_token" not in src:
    pos = src.find(ANCHOR_TFIR)
    if pos < 0:
        print("❌ try_factual_intent_routing anchor не найден", file=sys.stderr)
        sys.exit(3)
    src = src[:pos] + DATE_PARSER + src[pos:]
    print("✅ _parse_date_token injected")

# ====================================================================
# 3. Update try_factual_intent_routing to pass date
# ====================================================================
OLD_ROUTING = '''def try_factual_intent_routing(user_text: str):
    """Попробовать перехватить specific factual query ДО LLM.
    Returns string ответа если перехвачено, None если query должна идти в LLM."""
    if _CURRENCY_INTENT_RE.search(user_text):
        cur = _detect_currency_token(user_text)
        return get_nbrb_rate(cur)'''

NEW_ROUTING = '''def try_factual_intent_routing(user_text: str):
    """Попробовать перехватить specific factual query ДО LLM.
    DATE_PARSING v7 2026-05-18 — поддержка «вчера / в пятницу / 15.05».
    Returns string ответа если перехвачено, None если query должна идти в LLM."""
    if _CURRENCY_INTENT_RE.search(user_text):
        cur = _detect_currency_token(user_text)
        date = _parse_date_token(user_text)
        return get_nbrb_rate(cur, date=date)'''

if OLD_ROUTING in src:
    src = src.replace(OLD_ROUTING, NEW_ROUTING)
    print("✅ try_factual_intent_routing передаёт date")
else:
    print("⚠️  try_factual_intent_routing старая сигнатура не найдена — возможно v5b not applied", file=sys.stderr)

bot_py.write_text(src, encoding="utf-8")
print(f"\n✅ bot.py updated. Size: {len(src)} chars.")
PYEOF

[ $? -ne 0 ] && {
    echo "❌ Python error. Восстанавливаю backup..."
    cp "$BACKUP" "$BOT_PY"
    exit 4
}

echo ""
echo "==> py_compile check"
python3 -m py_compile "$BOT_PY" || {
    echo "❌ syntax error. Восстанавливаю backup..."
    cp "$BACKUP" "$BOT_PY"
    exit 5
}
echo "✅ py_compile OK"

echo ""
git --no-pager diff --stat -- bot.py
echo ""

git add bot.py
git commit -m "feat(v7): date parsing для get_nbrb_rate (вчера/в пятницу/15.05)

Юра msg 17913 (2026-05-18) — bug: «курс в пятницу» отвечал сегодняшней
датой. Root cause: get_nbrb_rate всегда current, intent routing не парсит
дату из user_text.

Changes:
1. get_nbrb_rate(currency, date=None): если date указана, &ondate=YYYY-MM-DD.
2. _parse_date_token(text): парсит 'сегодня/вчера/позавчера', дни недели
   ('в пятницу' → последний прошедший пт), '15.05', '15.05.2026', '15 мая'.
3. try_factual_intent_routing: извлекает date, передаёт в get_nbrb_rate.

Backup tag: pre-tools-v7. Откат: git reset --hard pre-tools-v7." 2>&1 | tail -5

echo ""
systemctl --user restart "$SERVICE" 2>&1 | tail -3
sleep 2
systemctl --user status "$SERVICE" --no-pager 2>&1 | head -6

echo ""
echo "✅ v7 applied. Tests:"
echo "  «курс доллара в пятницу» → курс на 2026-05-15"
echo "  «курс евро вчера» → курс на $(date -d 'yesterday' +%Y-%m-%d)"
echo "  «курс usd на 15.05» → курс на 2026-05-15"
echo "  «курс доллара сегодня» → курс на $(date +%Y-%m-%d)"
echo ""
echo "Откат: git reset --hard pre-tools-v7"
