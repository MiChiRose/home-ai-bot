#!/usr/bin/env bash
# add-tools-v5-currency-weather-news.sh
# Юра msg 17850 (2026-05-18) — v5 patch:
#   1. NBRB currency tool (api.nbrb.by JSON, no key needed)
#   2. gismeteo.by weather tool (HTML scrape)
#   3. SYSTEM_PROMPT routing rules для belta+onliner news
#   4. Rule «не упоминать источники в финальном ответе» (no URL citation)
#
# Apply via /run_patch на боте. Bot.py monolithic structure (~92KB).

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
BOT_PY="$BOT_DIR/bot.py"
SERVICE="${SERVICE:-home-ai-bot.service}"

cd "$BOT_DIR"

[ ! -f "$BOT_PY" ] && { echo "❌ $BOT_PY не найден"; exit 1; }

echo "==> BOT_DIR: $BOT_DIR"
echo "==> BOT_PY size: $(wc -l < "$BOT_PY") строк"

BACKUP="$BOT_DIR/bot.py.bak.before-tools-v5-$(date +%Y%m%d-%H%M%S)"
cp "$BOT_PY" "$BACKUP"
echo "✅ backup: $BACKUP"

git tag -f pre-tools-v5 "$(git rev-parse HEAD)" 2>/dev/null || true

BOT_PY="$BOT_PY" python3 - <<'PYEOF'
import os
import re
import sys
from pathlib import Path

bot_py = Path(os.environ["BOT_PY"])
src = bot_py.read_text(encoding="utf-8")

# ========================================================================
# 1. Inject tool functions get_nbrb_rate + get_gismeteo_weather
# ========================================================================
# Find a good anchor — after imports + before main bot logic.
# Use the imports section conclusion as anchor (last "import" block).

TOOLS_CODE = '''

# ============================================================
# Tool functions (v5 patch 2026-05-18) — direct factual sources
# ============================================================
import urllib.request as _urlreq
import urllib.error as _urlerr
import json as _json
import re as _re


def get_nbrb_rate(currency: str = "USD") -> str:
    """Получить официальный курс валюты НБРБ. Возвращает форматированную строку
    без упоминания источника."""
    cur = currency.upper().strip()
    cur_map = {"USD": "USD", "EUR": "EUR", "RUB": "RUB", "RUR": "RUB",
               "PLN": "PLN", "GBP": "GBP", "CNY": "CNY", "UAH": "UAH"}
    cur_code = cur_map.get(cur, cur)
    url = f"https://api.nbrb.by/exrates/rates/{cur_code}?parammode=2"
    try:
        req = _urlreq.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with _urlreq.urlopen(req, timeout=8) as resp:
            data = _json.loads(resp.read().decode("utf-8"))
        rate = data.get("Cur_OfficialRate")
        scale = data.get("Cur_Scale", 1)
        date = (data.get("Date") or "").split("T")[0]
        name = data.get("Cur_Name", cur_code)
        if rate is None:
            return f"Не удалось получить курс {cur_code}."
        # Если scale > 1, то rate указан за scale единиц
        if scale and scale != 1:
            return f"{scale} {name} = {rate} BYN (на {date})"
        return f"1 {name} = {rate} BYN (на {date})"
    except (_urlerr.URLError, _urlerr.HTTPError, TimeoutError, ValueError) as exc:
        return f"Не смог получить актуальный курс {cur_code}: {exc!r}"


def get_gismeteo_weather(city: str = "Минск") -> str:
    """Получить погоду через gismeteo.by HTML scrape. Возвращает текст без
    упоминания источника."""
    # Mapping городов → URL paths (расширяется по необходимости)
    city_paths = {
        "Минск": "minsk-4248",
        "Брест": "brest-4079",
        "Гомель": "gomel-4144",
        "Витебск": "vitebsk-4263",
        "Гродно": "grodno-4180",
        "Могилёв": "mogilev-4326", "Могилев": "mogilev-4326",
    }
    city_norm = city.strip().capitalize()
    path = city_paths.get(city_norm, "minsk-4248")
    url = f"https://www.gismeteo.by/weather-{path}/now/"
    try:
        req = _urlreq.Request(url, headers={"User-Agent": "Mozilla/5.0 (compatible)"})
        with _urlreq.urlopen(req, timeout=8) as resp:
            html = resp.read().decode("utf-8", errors="replace")
        # Извлекаем температуру и описание через regex по содержанию страницы.
        # Gismeteo использует aria-label с погодой; fallback на разные patterns.
        temp_match = _re.search(r'now-weather__temperature[^>]*>\\s*<[^>]*>\\s*([+-]?\\d+)', html)
        if not temp_match:
            temp_match = _re.search(r'"temperature":\\s*([+-]?\\d+)', html)
        if not temp_match:
            temp_match = _re.search(r'class="unit unit_temperature_c">([+-]?\\d+)', html)
        desc_match = _re.search(r'now-weather__description[^>]*>([^<]+)', html)
        if not desc_match:
            desc_match = _re.search(r'<meta\\s+name="description"\\s+content="([^"]+)"', html)
        temp = temp_match.group(1) if temp_match else "?"
        desc = (desc_match.group(1).strip() if desc_match else "").split(".")[0][:120]
        out = f"Сейчас в {city_norm}: {temp}°C"
        if desc:
            out += f". {desc}"
        return out
    except (_urlerr.URLError, _urlerr.HTTPError, TimeoutError) as exc:
        return f"Не смог получить погоду в {city_norm}: {exc!r}"


# Routing intent regex — для перехвата specific factual queries ДО web_search.
_CURRENCY_INTENT_RE = _re.compile(
    r"\\bкурс\\b.*\\b(доллар|евро|рубл|usd|eur|rub|pln|gbp|cny|uah)|"
    r"\\b(доллар|евро|usd|eur)\\b.*\\bкурс\\b",
    _re.IGNORECASE | _re.UNICODE,
)
_WEATHER_INTENT_RE = _re.compile(
    r"\\b(погод|температур|какая\\s+погода|сколько\\s+градус|осадк|дожд|снег)\\b",
    _re.IGNORECASE | _re.UNICODE,
)
_CURRENCY_TOKEN_MAP = {
    "доллар": "USD", "usd": "USD", "$": "USD",
    "евро": "EUR", "eur": "EUR", "€": "EUR",
    "рубл": "RUB", "rub": "RUB", "rur": "RUB",
    "злот": "PLN", "pln": "PLN",
    "фунт": "GBP", "gbp": "GBP",
    "юан": "CNY", "cny": "CNY",
    "гривн": "UAH", "uah": "UAH",
}


def _detect_currency_token(text: str) -> str:
    text_lower = text.lower()
    for token, code in _CURRENCY_TOKEN_MAP.items():
        if token in text_lower:
            return code
    return "USD"  # default


def _detect_city_token(text: str) -> str:
    text_lower = text.lower()
    cities = ["минск", "брест", "гомель", "витебск", "гродно", "могилёв", "могилев"]
    for city in cities:
        if city in text_lower:
            return city.capitalize()
    return "Минск"  # default


def try_factual_intent_routing(user_text: str):
    """Попробовать перехватить specific factual query ДО LLM.
    Returns string ответа если перехвачено, None если query должна идти в LLM."""
    if _CURRENCY_INTENT_RE.search(user_text):
        cur = _detect_currency_token(user_text)
        return get_nbrb_rate(cur)
    if _WEATHER_INTENT_RE.search(user_text):
        city = _detect_city_token(user_text)
        return get_gismeteo_weather(city)
    return None
'''

# Find anchor: после impmorts + перед первым def или class.
# Use heuristic — после первого блока imports, перед "def " line.
import_block_re = re.compile(r"^(?:from\s+\S+\s+import|import)\s+.*$", re.MULTILINE)
last_import_idx = 0
for m in import_block_re.finditer(src):
    last_import_idx = m.end()

if last_import_idx == 0:
    print("❌ Не нашёл import блок", file=sys.stderr)
    sys.exit(2)

# Inject TOOLS_CODE сразу после last import line
# Find end of that line
line_end = src.find("\n", last_import_idx)
if line_end == -1:
    line_end = last_import_idx

# Check if already injected
if "def get_nbrb_rate(" in src:
    print("ℹ️  Tool functions уже присутствуют. Skip injection.")
else:
    src = src[:line_end + 1] + TOOLS_CODE + src[line_end + 1:]
    print("✅ Injected tool functions get_nbrb_rate, get_gismeteo_weather, try_factual_intent_routing")

# ========================================================================
# 2. Add SYSTEM_PROMPT rule про БЕЛТА+Onliner новости + no-sources rule
# ========================================================================
# Anchor — после Belarus neutral context (v4) или после ПРОАКТИВНОСТЬ section

ANCHOR_BELARUS_V4 = "БЕЛАРУСЬ — НЕЙТРАЛЬНЫЕ ИСТОЧНИКИ"

if ANCHOR_BELARUS_V4 not in src:
    print(f"⚠️  v4 anchor не найден — нужно сначала применить v4 patch. Continuing...")
else:
    NEWS_AND_SOURCES_INJECTION = '''
                "НОВОСТИ БЕЛАРУСИ — ПРИОРИТЕТНЫЕ ИСТОЧНИКИ:\\n"
                "- При запросах «новости беларуси / минска / события сегодня» — формируй web_search query явно включая site:belta.by ИЛИ site:onliner.by. Эти источники приоритетные для новостной фактуры.\\n"
                "- Для свежих событий — добавляй в query фразу «сегодня» или дату вручную.\\n\\n"
                "НЕ УПОМИНАЙ ИСТОЧНИКИ В ФИНАЛЬНОМ ОТВЕТЕ:\\n"
                "- Запрещено перечислять URL / названия сайтов / упоминать «согласно X» / «по данным X» / «источник: X» в ответе юзеру.\\n"
                "- Выдавай готовый факт как утверждение. Юзеру не интересно откуда ты взял данные — ему интересен сам факт.\\n"
                "- Исключение: если юзер ЯВНО просит источник («откуда?», «дай ссылку», «подтверди источник») — тогда укажи.\\n\\n"
'''
    if "НОВОСТИ БЕЛАРУСИ — ПРИОРИТЕТНЫЕ ИСТОЧНИКИ" in src:
        print("ℹ️  News+no-sources rule уже присутствует. Skip.")
    else:
        # Find ENDING of v4 Belarus block (где она заканчивается \\n\\n")
        v4_pattern = re.compile(
            r'"' + ANCHOR_BELARUS_V4 + r'[^"]+(\\n\\n)"',
            re.DOTALL,
        )
        m = v4_pattern.search(src)
        if m:
            insert_pos = m.end()
            src = src[:insert_pos] + NEWS_AND_SOURCES_INJECTION + src[insert_pos:]
            print("✅ Injected news routing + no-sources-in-output rules в SYSTEM_PROMPT")
        else:
            print("⚠️  v4 anchor найден но не удалось найти конец блока. Manual review нужен.")

# ========================================================================
# 3. Wire try_factual_intent_routing в основной message handler
# ========================================================================
# Найти main user message handler (где обрабатывается incoming text)
# Anchor: heuristic — first call to "instruct" branch
# Это требует кастомной интеграции, посчитаем как partial — пользователь
# может вручную добавить вызов try_factual_intent_routing(user_text)
# в начало handler ДО запуска web_search.

print("⚠️  3-я часть (wire try_factual_intent_routing в handler) — НЕ автоматизирована.")
print("   В bot.py найти main user-message handler и добавить в начало:")
print("       early_answer = try_factual_intent_routing(user_text)")
print("       if early_answer is not None:")
print("           await reply_to_user(early_answer); return")
print("   ПОСЛЕ применения patch'а — отдельный round-trip для wiring.")

bot_py.write_text(src, encoding="utf-8")
print(f"\\n✅ bot.py updated. Size: {len(src)} chars.")
PYEOF

[ $? -ne 0 ] && {
    echo "❌ Python injection error. Восстанавливаю backup..."
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
echo "==> git diff stat"
git --no-pager diff --stat -- bot.py

echo ""
echo "==> commit"
git add bot.py
git commit -m "feat(v5): currency NBRB tool + gismeteo weather tool + news routing + no-sources rule

Юра msg 17850 (2026-05-18) — v5 patch.

Added in bot.py (monolithic structure):
1. get_nbrb_rate(currency) — direct fetch api.nbrb.by JSON (8 currencies)
2. get_gismeteo_weather(city) — HTML scrape gismeteo.by (6 cities)
3. try_factual_intent_routing(text) — regex catch ДО LLM:
   - 'курс|usd|eur|rub|...' → get_nbrb_rate
   - 'погод|температур|осадк|...' → get_gismeteo_weather
4. SYSTEM_PROMPT additions:
   - НОВОСТИ БЕЛАРУСИ: query с site:belta.by site:onliner.by
   - NO SOURCES IN OUTPUT: не упоминать URL/источники/'согласно X'

Note: integration в main handler requires manual wiring — нужно вызывать
try_factual_intent_routing(user_text) перед запуском web_search loop.
См. инструкции на stdout patch run." 2>&1 | tail -5

echo ""
echo "==> restart $SERVICE"
systemctl --user restart "$SERVICE" 2>&1 | tail -3
sleep 2
systemctl --user status "$SERVICE" --no-pager 2>&1 | head -8

echo ""
echo "✅ v5 patch applied. Test:"
echo "  Спроси «курс доллара» → должно быть точное число с api.nbrb.by"
echo "  Спроси «погода в Минске» → температура + описание с gismeteo.by"
echo ""
echo "Откат:"
echo "  git reset --hard pre-tools-v5"
echo "  cp '$BACKUP' '$BOT_PY'"
echo "  systemctl --user restart $SERVICE"
