#!/usr/bin/env bash
# v13 — Юра msg 17962: «Сейчас в Минск: ?°C» — get_gismeteo_weather парсит
# gismeteo.by HTML который сломался (JS-рендеринг или сменили layout).
#
# Fix: переключить с HTML-scraping gismeteo.by на JSON API wttr.in
# (надёжнее, simple GET, без авторизации, любой город мира).

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
BOT_PY="$BOT_DIR/bot.py"
SERVICE="${SERVICE:-home-ai-bot.service}"

cd "$BOT_DIR"
[ ! -f "$BOT_PY" ] && { echo "❌ $BOT_PY не найден"; exit 1; }

BACKUP="$BOT_DIR/bot.py.bak.before-tools-v13-$(date +%Y%m%d-%H%M%S)"
cp "$BOT_PY" "$BACKUP"

git tag -f pre-tools-v13 "$(git rev-parse HEAD)" 2>/dev/null || true

BOT_PY="$BOT_PY" python3 - <<'PYEOF'
import os, re, sys
from pathlib import Path

bot_py = Path(os.environ["BOT_PY"])
src = bot_py.read_text(encoding="utf-8")

if "WTTR_WEATHER v13" in src:
    print("ℹ️  v13 уже применён. Skip.")
    sys.exit(0)

# Найти существующий get_gismeteo_weather (любой вариант — v5 / v5b)
old_pattern = re.compile(
    r"def get_gismeteo_weather\(city: str = \"Минск\"\) -> str:.*?(?=\n\ndef |\n\nclass |\n\n_|\n# ===|\nasync def )",
    re.DOTALL,
)
m = old_pattern.search(src)
if not m:
    print("❌ get_gismeteo_weather не найден", file=sys.stderr)
    sys.exit(2)

NEW_WEATHER = '''def get_gismeteo_weather(city: str = "Минск") -> str:
    """WTTR_WEATHER v13 2026-05-18.
    Получить текущую погоду через wttr.in JSON API.
    Совместимая сигнатура (имя оставлено для backward compat с _factual_routing).
    Поддерживает любой город (не только РБ); fall-through к LLM в routing
    остаётся для не-распознанных городов (v9 logic)."""
    import urllib.parse as _up
    city_q = _up.quote(city)
    url = f"https://wttr.in/{city_q}?format=j1&lang=ru"
    try:
        req = _urlreq.Request(url, headers={"User-Agent": "curl/8.0"})
        with _urlreq.urlopen(req, timeout=10) as resp:
            data = _json.loads(resp.read().decode("utf-8"))
        current = data.get("current_condition", [{}])[0]
        temp_c = current.get("temp_C", "?")
        feels_c = current.get("FeelsLikeC", temp_c)
        desc_list = current.get("lang_ru") or current.get("weatherDesc", [])
        desc = desc_list[0].get("value", "—") if desc_list else "—"
        wind = current.get("windspeedKmph", "?")
        humidity = current.get("humidity", "?")
        return (
            f"Погода в {city}: {temp_c}°C ({desc.lower()}), "
            f"ощущается как {feels_c}°C. "
            f"Ветер {wind} км/ч, влажность {humidity}%."
        )
    except (_urlerr.URLError, _urlerr.HTTPError, TimeoutError, ValueError, KeyError, IndexError) as exc:
        return f"Не смог получить погоду для {city}: {exc!r}"
'''

src = src[:m.start()] + NEW_WEATHER + src[m.end():]
print("✅ get_gismeteo_weather заменён на wttr.in JSON API (WTTR_WEATHER v13)")

bot_py.write_text(src, encoding="utf-8")
print(f"✅ bot.py updated. Size: {len(src)} chars.")
PYEOF

[ $? -ne 0 ] && { cp "$BACKUP" "$BOT_PY"; exit 4; }
python3 -m py_compile "$BOT_PY" || { cp "$BACKUP" "$BOT_PY"; exit 5; }
echo "✅ py_compile OK"

git add bot.py
git commit -m "fix(v13): погода через wttr.in JSON API (вместо HTML scrape gismeteo.by)

Юра msg 17962 (2026-05-18): бот вернул '?°C' для Минска — gismeteo.by
сменили HTML или включили JS-рендеринг, наш HTML scraper сломался.

Replacement: wttr.in JSON API.
- Бесплатный, без авторизации, simple GET
- Поддерживает любой город мира, русский язык в weatherDesc
- Возвращает temp_C, FeelsLikeC, windspeedKmph, humidity, weatherDesc

Сигнатура функции сохранена для backward compat с try_factual_intent_routing.
v9 fall-through логика для не-РБ городов остаётся как safety net.

Backup tag: pre-tools-v13. Откат: git reset --hard pre-tools-v13." 2>&1 | tail -5

systemctl --user restart "$SERVICE" 2>&1 | tail -3
sleep 2

echo ""
echo "✅ v13 applied. Tests:"
echo "  «погода в Минске» → 17°C, ощущается 17°C, partly cloudy, ветер X км/ч"
echo "  «погода в Тюмени» → fall-through к LLM (v9 logic)"
echo ""
echo "Откат: git reset --hard pre-tools-v13"
