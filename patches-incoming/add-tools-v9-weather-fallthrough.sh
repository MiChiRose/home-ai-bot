#!/usr/bin/env bash
# v9 — Юра msg 17934: погода для не-беларуских городов всё равно возвращает Минск.
#
# Root cause: _detect_city_token падает на default «Минск» если в тексте
# нет одного из шести беларуских городов. try_factual_intent_routing
# всегда intercept'ит weather query → отдаёт минскую погоду.
#
# Fix:
# - _detect_city_token возвращает None если ни одного беларуского города нет
# - try_factual_intent_routing для weather: если city is None → return None
#   (fall through к LLM, который ходит в web_search и достанет погоду
#   через generic поиск)

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
BOT_PY="$BOT_DIR/bot.py"
SERVICE="${SERVICE:-home-ai-bot.service}"

cd "$BOT_DIR"
[ ! -f "$BOT_PY" ] && { echo "❌ $BOT_PY не найден"; exit 1; }

BACKUP="$BOT_DIR/bot.py.bak.before-tools-v9-$(date +%Y%m%d-%H%M%S)"
cp "$BOT_PY" "$BACKUP"
echo "✅ backup: $BACKUP"

git tag -f pre-tools-v9 "$(git rev-parse HEAD)" 2>/dev/null || true

BOT_PY="$BOT_PY" python3 - <<'PYEOF'
import os, sys
from pathlib import Path

bot_py = Path(os.environ["BOT_PY"])
src = bot_py.read_text(encoding="utf-8")

if "WEATHER_FALLTHROUGH v9" in src:
    print("ℹ️  v9 уже применён. Skip.")
    sys.exit(0)

# === 1. _detect_city_token: возвращать None для не-беларуских городов ===
OLD_DETECT = '''def _detect_city_token(text: str) -> str:
    text_lower = text.lower()
    cities = ["минск", "брест", "гомель", "витебск", "гродно", "могилёв", "могилев"]
    for city in cities:
        if city in text_lower:
            return city.capitalize()
    return "Минск"  # default'''

NEW_DETECT = '''def _detect_city_token(text: str) -> str | None:
    """WEATHER_FALLTHROUGH v9 2026-05-18.
    Возвращает беларуский город из текста, или None если не найден
    (тогда intent routing fall through'нет к LLM)."""
    text_lower = text.lower()
    cities = ["минск", "брест", "гомель", "витебск", "гродно", "могилёв", "могилев"]
    for city in cities:
        if city in text_lower:
            return city.capitalize()
    return None  # let LLM handle non-Belarus cities via web_search'''

if OLD_DETECT in src:
    src = src.replace(OLD_DETECT, NEW_DETECT)
    print("✅ _detect_city_token: default Минск → None")
else:
    print("❌ _detect_city_token signature не найден", file=sys.stderr)
    sys.exit(2)

# === 2. try_factual_intent_routing — guard для city is None ===
OLD_ROUTING = '''    if _WEATHER_INTENT_RE.search(user_text):
        city = _detect_city_token(user_text)
        return get_gismeteo_weather(city)'''

NEW_ROUTING = '''    if _WEATHER_INTENT_RE.search(user_text):
        city = _detect_city_token(user_text)
        if city is None:
            return None  # WEATHER_FALLTHROUGH v9: не-беларуский город → к LLM с web_search
        return get_gismeteo_weather(city)'''

if OLD_ROUTING in src:
    src = src.replace(OLD_ROUTING, NEW_ROUTING)
    print("✅ try_factual_intent_routing: weather fall-through для не-беларуских")
else:
    print("⚠️  WEATHER routing старая сигнатура не найдена", file=sys.stderr)

bot_py.write_text(src, encoding="utf-8")
print(f"\n✅ bot.py updated. Size: {len(src)} chars.")
PYEOF

[ $? -ne 0 ] && { cp "$BACKUP" "$BOT_PY"; exit 4; }
python3 -m py_compile "$BOT_PY" || { cp "$BACKUP" "$BOT_PY"; exit 5; }
echo "✅ py_compile OK"

git add bot.py
git commit -m "fix(v9): weather fall-through для не-беларуских городов

Юра msg 17934 (2026-05-18): русский user спросит «погода в Тюмени» —
бот возвращал минскую погоду (default из _detect_city_token).

Fix:
- _detect_city_token: default «Минск» → None
- try_factual_intent_routing: если city is None → return None
  → LLM достанет погоду через web_search, ходит в gismeteo.ru/Яндекс.Погода

Беларуские города (Минск/Брест/Гомель/Витебск/Гродно/Могилёв) остаются
deterministic через gismeteo.by intercept.

Backup tag: pre-tools-v9. Откат: git reset --hard pre-tools-v9." 2>&1 | tail -5

systemctl --user restart "$SERVICE" 2>&1 | tail -3
sleep 2
systemctl --user status "$SERVICE" --no-pager 2>&1 | head -6

echo ""
echo "✅ v9 applied. Tests:"
echo "  «погода в Минске» → deterministic gismeteo.by Минск"
echo "  «погода в Тюмени» → LLM web_search (Тюмень)"
echo "  «погода в Москве» → LLM web_search (Москва)"
echo "  «какая погода» (без города) → LLM решает context"
echo ""
echo "Откат: git reset --hard pre-tools-v9"
