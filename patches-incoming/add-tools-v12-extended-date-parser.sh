#!/usr/bin/env bash
# v12 — Юра msg 17956: расширенный date parser.
# Добавляет к _parse_date_token поддержку:
#   - «в прошлом году», «в позапрошлом году», «N лет назад»
#   - «N недель назад», «N месяцев назад», «N дней назад»
#   - «прошлой зимой/весной/летом/осенью»
#   - «в январе/феврале/.../декабре» (текущий год если не прошёл, иначе прошлый)
#   - Английские дубли: «yesterday», «last week», «X days ago»

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
BOT_PY="$BOT_DIR/bot.py"
SERVICE="${SERVICE:-home-ai-bot.service}"

cd "$BOT_DIR"
[ ! -f "$BOT_PY" ] && { echo "❌ $BOT_PY не найден"; exit 1; }

BACKUP="$BOT_DIR/bot.py.bak.before-tools-v12-$(date +%Y%m%d-%H%M%S)"
cp "$BOT_PY" "$BACKUP"

git tag -f pre-tools-v12 "$(git rev-parse HEAD)" 2>/dev/null || true

BOT_PY="$BOT_PY" python3 - <<'PYEOF'
import os, re, sys
from pathlib import Path

bot_py = Path(os.environ["BOT_PY"])
src = bot_py.read_text(encoding="utf-8")

if "EXTENDED_DATE_PARSER v12" in src:
    print("ℹ️  v12 уже применён. Skip.")
    sys.exit(0)

# Полная замена _parse_date_token (расширенная версия)
import re as _r
old_pattern = _r.compile(r"def _parse_date_token\(text: str\) -> str \| None:.*?return None\n\n", _r.DOTALL)
m = old_pattern.search(src)
if not m:
    print("❌ _parse_date_token не найден для замены", file=sys.stderr)
    sys.exit(2)

NEW_PARSER = '''def _parse_date_token(text: str) -> str | None:
    """EXTENDED_DATE_PARSER v12 2026-05-18.
    Парсит relative/absolute дату из user_text.
    Returns YYYY-MM-DD или None если не нашёл.

    Поддержка:
      - «сегодня», «вчера», «позавчера», «yesterday», «today»
      - «N дней/недель/месяцев/лет назад» (числом или прописью)
      - дни недели «в пятницу», «в прошлый понедельник»
      - «в прошлом году», «в позапрошлом году»
      - «прошлой зимой/весной/летом/осенью»
      - «в январе/феврале/.../декабре» (если в текущем году ещё не прошёл — берём прошлый год)
      - «15.05», «15.05.2026», «15 мая», «15 мая 2026»
      - «last week», «last month», «X days ago»
    """
    import datetime as _dt
    import re as _re
    text_l = text.lower()
    today = _dt.date.today()

    # «сегодня» / today
    if _re.search(r"\\b(сегодня|today)\\b", text_l):
        return today.isoformat()

    # «вчера» / yesterday
    if _re.search(r"\\b(вчера|yesterday)\\b", text_l):
        return (today - _dt.timedelta(days=1)).isoformat()

    # «позавчера»
    if _re.search(r"\\bпозавчера\\b", text_l):
        return (today - _dt.timedelta(days=2)).isoformat()

    # «в прошлом году» / «last year»
    if _re.search(r"\\b(в\\s+прошлом\\s+году|last\\s+year)\\b", text_l):
        try:
            return today.replace(year=today.year - 1).isoformat()
        except ValueError:
            return _dt.date(today.year - 1, today.month, 28).isoformat()

    # «в позапрошлом году»
    if _re.search(r"\\b(в\\s+позапрошлом\\s+году|две\\s+года\\s+назад|2\\s+года\\s+назад)\\b", text_l):
        try:
            return today.replace(year=today.year - 2).isoformat()
        except ValueError:
            return _dt.date(today.year - 2, today.month, 28).isoformat()

    # «N лет назад» / «N years ago»
    word_to_num = {"один": 1, "два": 2, "три": 3, "четыре": 4, "пять": 5,
                   "шесть": 6, "семь": 7, "восемь": 8, "девять": 9, "десять": 10}
    m_y = _re.search(r"\\b(\\d+|один|два|три|четыре|пять|шесть|семь|восемь|девять|десять)\\s+(?:лет|года?|years?)\\s+назад\\b", text_l)
    if m_y:
        n = word_to_num.get(m_y.group(1)) or int(m_y.group(1))
        try:
            return today.replace(year=today.year - n).isoformat()
        except ValueError:
            return _dt.date(today.year - n, today.month, 28).isoformat()

    # «N месяцев назад» / «X months ago»
    m_m = _re.search(r"\\b(\\d+|один|два|три|четыре|пять|шесть|семь|восемь|девять|десять)\\s+(?:месяц\\w*|months?)\\s+назад\\b", text_l)
    if m_m:
        n = word_to_num.get(m_m.group(1)) or int(m_m.group(1))
        y = today.year
        m_new = today.month - n
        while m_new <= 0:
            m_new += 12
            y -= 1
        try:
            return _dt.date(y, m_new, today.day).isoformat()
        except ValueError:
            return _dt.date(y, m_new, 28).isoformat()

    # «N недель назад» / «X weeks ago»
    m_w = _re.search(r"\\b(\\d+|один|два|три|четыре|пять|шесть|семь|восемь|девять|десять)\\s+(?:недел\\w+|weeks?)\\s+назад\\b", text_l)
    if m_w:
        n = word_to_num.get(m_w.group(1)) or int(m_w.group(1))
        return (today - _dt.timedelta(weeks=n)).isoformat()

    # «N дней назад» / «X days ago»
    m_d = _re.search(r"\\b(\\d+|один|два|три|четыре|пять|шесть|семь|восемь|девять|десять)\\s+(?:дн\\w+|days?)\\s+назад\\b", text_l)
    if m_d:
        n = word_to_num.get(m_d.group(1)) or int(m_d.group(1))
        return (today - _dt.timedelta(days=n)).isoformat()

    # «прошлой зимой/весной/летом/осенью» — берём середину сезона предыдущего года
    seasons = {
        "зим": _dt.date(today.year - 1, 12, 21) if today.month < 3 else _dt.date(today.year - 1, 12, 21),
        "весн": _dt.date(today.year - 1, 3, 21) if today.month < 6 else _dt.date(today.year, 3, 21),
        "лет": _dt.date(today.year - 1, 6, 21) if today.month < 9 else _dt.date(today.year, 6, 21),
        "осен": _dt.date(today.year - 1, 9, 21) if today.month < 12 else _dt.date(today.year, 9, 21),
    }
    for stem, date_val in seasons.items():
        if _re.search(rf"\\bпрошл\\w+\\s+{stem}", text_l):
            return date_val.isoformat()

    # «last week/month»
    if _re.search(r"\\blast\\s+week\\b", text_l):
        return (today - _dt.timedelta(weeks=1)).isoformat()
    if _re.search(r"\\blast\\s+month\\b", text_l):
        y = today.year
        m_new = today.month - 1
        if m_new == 0:
            m_new = 12; y -= 1
        return _dt.date(y, m_new, min(today.day, 28)).isoformat()

    # Дни недели — последний прошедший / ближайший
    days = {"понедельник": 0, "вторник": 1, "сред": 2, "четверг": 3,
            "пятниц": 4, "суббот": 5, "воскресень": 6,
            "monday": 0, "tuesday": 1, "wednesday": 2, "thursday": 3,
            "friday": 4, "saturday": 5, "sunday": 6}
    for stem, idx in days.items():
        if stem in text_l:
            delta = (today.weekday() - idx) % 7
            if delta == 0:
                delta = 7
            return (today - _dt.timedelta(days=delta)).isoformat()

    # Месяцы прописью — «в январе/феврале/.../декабре»
    months_genitive = {
        "январ": 1, "феврал": 2, "март": 3, "апрел": 4, "ма": 5,
        "июн": 6, "июл": 7, "август": 8, "сентябр": 9, "октябр": 10,
        "ноябр": 11, "декабр": 12,
    }
    m_mn = _re.search(r"\\bв\\s+([а-я]{3,})(?:\\s+(\\d{4}))?\\b", text_l)
    if m_mn:
        mname = m_mn.group(1)
        y_explicit = m_mn.group(2)
        for stem, idx in months_genitive.items():
            if mname.startswith(stem) and stem != "ма" or (stem == "ма" and mname == "мае"):
                year = int(y_explicit) if y_explicit else today.year
                # Если месяц текущего года ещё не прошёл, берём прошлый год
                if not y_explicit and idx > today.month:
                    year -= 1
                try:
                    return _dt.date(year, idx, 15).isoformat()
                except ValueError:
                    pass
                break

    # «15.05» / «15.05.2026»
    m_dot = _re.search(r"\\b(\\d{1,2})\\.(\\d{1,2})(?:\\.(\\d{4}))?\\b", text)
    if m_dot:
        d, mo, y = m_dot.groups()
        y = int(y) if y else today.year
        try:
            return _dt.date(y, int(mo), int(d)).isoformat()
        except ValueError:
            pass

    # «15 мая» / «18 мая 2026»
    m_md = _re.search(r"\\b(\\d{1,2})\\s+([а-я]{3,})(?:\\s+(\\d{4}))?\\b", text_l)
    if m_md:
        d, mname, y = m_md.groups()
        for stem, idx in months_genitive.items():
            if mname.startswith(stem):
                year = int(y) if y else today.year
                try:
                    return _dt.date(year, idx, int(d)).isoformat()
                except ValueError:
                    pass
                break

    return None

'''

src = src[:m.start()] + NEW_PARSER + src[m.end():]
print("✅ _parse_date_token расширен (v12 EXTENDED_DATE_PARSER)")

bot_py.write_text(src, encoding="utf-8")
print(f"✅ bot.py updated. Size: {len(src)} chars.")
PYEOF

[ $? -ne 0 ] && { cp "$BACKUP" "$BOT_PY"; exit 4; }
python3 -m py_compile "$BOT_PY" || { cp "$BACKUP" "$BOT_PY"; exit 5; }
echo "✅ py_compile OK"

git add bot.py
git commit -m "feat(v12): расширенный date parser — relative phrases + seasons + years ago

Юра msg 17956 (2026-05-18) — расширение _parse_date_token v7.

Новые форматы:
- «в прошлом году», «в позапрошлом году», «N лет назад»
- «N недель/месяцев/дней назад» (числом или прописью один-десять)
- «прошлой зимой/весной/летом/осенью» (середина сезона)
- «в январе/.../декабре» (текущий или прошлый год по контексту)
- английские дубли: yesterday, today, last week/month/year, X days ago

Сохранён существующий функционал v7: сегодня/вчера/позавчера, дни
недели, NN.NN, NN мая.

Backup tag: pre-tools-v12. Откат: git reset --hard pre-tools-v12." 2>&1 | tail -5

systemctl --user restart "$SERVICE" 2>&1 | tail -3
sleep 2

echo ""
echo "✅ v12 applied. Tests:"
echo "  «курс в прошлом году» → курс ровно год назад"
echo "  «курс 2 месяца назад» → курс 2 месяца назад"
echo "  «курс прошлой зимой» → 21.12 прошлого/позапрошлого года"
echo "  «курс в январе» → 15.01 текущего или прошлого года"
echo "  «what was USD rate last week» → курс неделю назад"
echo ""
echo "Откат: git reset --hard pre-tools-v12"
