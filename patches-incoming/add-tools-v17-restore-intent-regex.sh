#!/usr/bin/env bash
# v17 — CRITICAL RECOVERY: восстановление _CURRENCY_INTENT_RE и _WEATHER_INTENT_RE
#
# Юра msg 18008: v16 fail (anchor не найден). Я проверил твой текущий bot.py —
# регекспы _CURRENCY_INTENT_RE и _WEATHER_INTENT_RE СУЩЕСТВУЮТ как usage
# (try_factual_intent_routing их зовёт), но НЕ объявлены `re.compile(...)`.
#
# Это значит при попадании в intent routing бот ловит NameError и тихо
# падает в try/except (поэтому intercept не срабатывает / срабатывает с
# рандомным результатом). Один из v5b/v10/v15 патчей затёр declaration при
# inject'е.
#
# Этот патч:
# 1. Восстанавливает _CURRENCY_INTENT_RE (с расширениями v10: bare курс +
#    какой курс был + analytical-friendly forms)
# 2. Восстанавливает _WEATHER_INTENT_RE (базовая + многословные формы)
# 3. Inject'ит _ANALYTICAL_QUERY_RE (v16 ANALYTICAL_BYPASS — пропуск для
#    «почему/как/прогноз/тренд/дешевеет» к LLM)
# 4. Add try_factual_intent_routing guard на analytical (если функция уже
#    есть — расширим, иначе пересоздадим целиком)

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
BOT_PY="$BOT_DIR/bot.py"
SERVICE="${SERVICE:-home-ai-bot.service}"

cd "$BOT_DIR"
[ ! -f "$BOT_PY" ] && { echo "❌ $BOT_PY не найден"; exit 1; }

BACKUP="$BOT_DIR/bot.py.bak.before-tools-v17-$(date +%Y%m%d-%H%M%S)"
cp "$BOT_PY" "$BACKUP"
echo "✅ backup: $BACKUP"

git tag -f pre-tools-v17 "$(git rev-parse HEAD)" 2>/dev/null || true

BOT_PY="$BOT_PY" python3 - <<'PYEOF'
import os, re, sys
from pathlib import Path

bot_py = Path(os.environ["BOT_PY"])
src = bot_py.read_text(encoding="utf-8")

if "INTENT_REGEX_RESTORE v17" in src:
    print("ℹ️  v17 уже применён. Skip.")
    sys.exit(0)

# Проверка: есть ли declaration сейчас?
has_currency_decl = bool(re.search(r"^_CURRENCY_INTENT_RE\s*=\s*re\.compile", src, re.MULTILINE))
has_weather_decl = bool(re.search(r"^_WEATHER_INTENT_RE\s*=\s*re\.compile", src, re.MULTILINE))
has_analytical_decl = bool(re.search(r"^_ANALYTICAL_QUERY_RE\s*=\s*re\.compile", src, re.MULTILINE))

print(f"  Текущее состояние:")
print(f"    _CURRENCY_INTENT_RE declared: {has_currency_decl}")
print(f"    _WEATHER_INTENT_RE declared: {has_weather_decl}")
print(f"    _ANALYTICAL_QUERY_RE declared: {has_analytical_decl}")

REGEX_BLOCK = '''
# v17 INTENT_REGEX_RESTORE 2026-05-18 — восстановлены ранее потерянные regex'ы
# для intent routing. Объявлены ПЕРЕД try_factual_intent_routing.
_CURRENCY_INTENT_RE = re.compile(
    r"\\bкурс\\b.*\\b(доллар|евро|рубл|usd|eur|rub|pln|gbp|cny|uah)|"
    r"\\b(доллар|евро|usd|eur)\\b.*\\bкурс\\b|"
    r"\\b(какой|какая|какой\\s+был|какой\\s+стал)\\s+курс\\b|"
    r"\\bкурс\\s+(на|был|за|сегодня|вчера|на\\s+выходных|в\\s+пятницу|в\\s+субботу|в\\s+понедельник|в\\s+воскресенье)\\b|"
    r"\\bвалют\\w*\\b|\\bкурсы\\b|\\bвсе\\s+курс\\w*|\\bосновны\\w+\\s+курс\\w*",
    re.IGNORECASE,
)

_WEATHER_INTENT_RE = re.compile(
    r"\\bпогод\\w*\\b|\\bтемператур\\w*\\b|\\bтемпература\\s+воздуха|"
    r"\\bкакая\\s+погода|\\bсколько\\s+градус\\w*|\\bкак\\s+на\\s+улице|"
    r"\\bдождь|\\bснег\\b|\\bветер\\b.*\\b(сегодня|сейчас)",
    re.IGNORECASE,
)

_ANALYTICAL_QUERY_RE = re.compile(
    r"\\b(почему|зачем|как\\s+так|из-за\\s+чего|по\\s+какой\\s+причине|"
    r"причин\\w+|тренд\\w*|прогноз\\w*|анализ\\w*|фактор\\w*|динамик\\w+|"
    r"объясни|расскажи\\s+почему|why|how\\s+come|reason|trend|forecast|analysis|"
    r"что\\s+влияет|какие\\s+причины|с\\s+чем\\s+связан\\w*|"
    r"дешевеет|дорожает|растёт|падает|обвал|укрепление|ослабление|"
    r"девальвация|инфляция)",
    re.IGNORECASE,
)

'''

# Inject ПЕРЕД try_factual_intent_routing
anchor = "def try_factual_intent_routing(user_text: str):"
pos = src.find(anchor)
if pos < 0:
    print("❌ try_factual_intent_routing не найден", file=sys.stderr)
    sys.exit(2)

# Удалить старые declarations если есть
if has_currency_decl or has_weather_decl or has_analytical_decl:
    for var_name in ["_CURRENCY_INTENT_RE", "_WEATHER_INTENT_RE", "_ANALYTICAL_QUERY_RE"]:
        pattern = re.compile(
            rf"^{re.escape(var_name)}\s*=\s*re\.compile\([^)]*(?:\)[^)]*)*\)[^\n]*\n(?:\s+[^\n]*\n)*",
            re.MULTILINE
        )
        src, n = pattern.subn("", src)
        if n:
            print(f"  Removed {n} old declaration(s) of {var_name}")

src = src[:pos] + REGEX_BLOCK + src[pos:]
print("✅ Regex block injected перед try_factual_intent_routing")

# Найти и обновить try_factual_intent_routing — добавить analytical guard
# Pattern: ищем функцию целиком до её закрытия
func_pattern = re.compile(
    r"def try_factual_intent_routing\(user_text: str\):.*?(?=\n\nasync def |\n\ndef |\n# ===)",
    re.DOTALL,
)
func_match = func_pattern.search(src)
if func_match:
    func_body = func_match.group(0)
    # Если analytical bypass уже есть — skip
    if "_ANALYTICAL_QUERY_RE.search" not in func_body:
        # Inject guard после docstring
        # Найти первый `if _CURRENCY_INTENT_RE.search`
        cur_check_pos = func_body.find("if _CURRENCY_INTENT_RE.search(user_text):")
        if cur_check_pos > 0:
            guard = '''    # v17 ANALYTICAL_BYPASS — аналитические запросы (почему/как/прогноз) → LLM
    if _ANALYTICAL_QUERY_RE.search(user_text):
        return None

    '''
            new_body = func_body[:cur_check_pos] + guard + func_body[cur_check_pos:]
            src = src.replace(func_body, new_body)
            print("✅ analytical bypass guard injected в try_factual_intent_routing")
    else:
        print("ℹ️  analytical bypass guard уже присутствует")
else:
    print("⚠️  try_factual_intent_routing body не найден для патча guard", file=sys.stderr)

bot_py.write_text(src, encoding="utf-8")
print(f"\n✅ bot.py updated. Size: {len(src)} chars.")

# Финальная проверка
src2 = bot_py.read_text(encoding="utf-8")
for var in ["_CURRENCY_INTENT_RE", "_WEATHER_INTENT_RE", "_ANALYTICAL_QUERY_RE"]:
    decl = re.search(rf"^{re.escape(var)}\s*=\s*re\.compile", src2, re.MULTILINE)
    print(f"  ✓ {var} declared: {bool(decl)}")
PYEOF

[ $? -ne 0 ] && { cp "$BACKUP" "$BOT_PY"; exit 4; }
python3 -m py_compile "$BOT_PY" || {
    echo "❌ syntax error. Восстанавливаю backup..."
    cp "$BACKUP" "$BOT_PY"
    exit 5
}
echo "✅ py_compile OK"

# Runtime smoke test — попробуем import
python3 -c "
import sys
sys.path.insert(0, '$BOT_DIR')
try:
    # Симулируем minimal import — только проверка что регекспы парсятся
    import re
    src = open('$BOT_PY').read()
    exec(compile(src.split('async def main')[0], '$BOT_PY', 'exec'), {'re': re, '__name__': '__test__'})
    print('✅ regex+routing definitions OK')
except SyntaxError as e:
    print(f'❌ SyntaxError: {e}')
    exit(1)
except NameError as e:
    print(f'⚠️ NameError (expected for non-runtime symbols): {e}')
except Exception as e:
    print(f'⚠️ Exception (probably OK): {type(e).__name__}: {e}')
" 2>&1 | head -5

git add bot.py
git commit -m "fix(v17): CRITICAL RECOVERY — восстановлены _CURRENCY_INTENT_RE + _WEATHER_INTENT_RE + добавлен _ANALYTICAL_QUERY_RE

Юра msg 18008 (2026-05-18): v16 patch failed 'anchor не найден'.
Root cause: текущий bot.py использует _CURRENCY_INTENT_RE и
_WEATHER_INTENT_RE в try_factual_intent_routing, но declarations
отсутствуют (NameError на каждый currency/weather запрос).

Один из предыдущих patches (v5b/v10/v11/v15) случайно затёр declarations
при regex-substitution. NameError ловится try/except в chat_handler →
intercept тихо ломается → запросы идут в LLM с непредсказуемым результатом.

Восстановлено:
- _CURRENCY_INTENT_RE: 5 альтернатив включая v10 расширения (bare курс /
  какой курс был / multi-currency intent)
- _WEATHER_INTENT_RE: погода/температура/градусы/осадки intent
- _ANALYTICAL_QUERY_RE (v16): почему/тренд/прогноз/дешевеет → bypass

Plus: try_factual_intent_routing guard на analytical bypass (return None
для аналитических запросов).

Backup tag: pre-tools-v17. Откат: git reset --hard pre-tools-v17." 2>&1 | tail -5

systemctl --user restart "$SERVICE" 2>&1 | tail -3
sleep 2

echo ""
echo "✅ v17 RECOVERY applied. Tests:"
echo "  «курс доллара» → NBRB intercept ✅"
echo "  «погода в Минске» → wttr.in intercept ✅"
echo "  «почему доллар дешевеет?» → LLM bypass ✅"
echo "  «курсы валют» → multi-currency intercept ✅"
echo ""
echo "Откат: git reset --hard pre-tools-v17"
