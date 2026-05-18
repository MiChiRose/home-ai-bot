#!/usr/bin/env bash
# v16 — Юра msg 17992: «почему доллар дешевеет?» получил «курс 2.7535 BYN»
# (intercept перепутал analytical query с factual rate request).
#
# Fix:
# 1. _ANALYTICAL_QUERY_RE — новый regex для маркеров аналитического запроса:
#    почему / как / зачем / из-за / причина / тренд / прогноз / анализ / фактор / динамика.
# 2. try_factual_intent_routing — если match, ВСЕГДА return None
#    (skip intercept → LLM с web_search обработает осмысленно).
# 3. SYSTEM_PROMPT rule — явно говорит что аналитические вопросы о валюте
#    → НЕ давать просто число курса, идти в web_search за объяснением.

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
BOT_PY="$BOT_DIR/bot.py"
SERVICE="${SERVICE:-home-ai-bot.service}"

cd "$BOT_DIR"
[ ! -f "$BOT_PY" ] && { echo "❌ $BOT_PY не найден"; exit 1; }

BACKUP="$BOT_DIR/bot.py.bak.before-tools-v16-$(date +%Y%m%d-%H%M%S)"
cp "$BOT_PY" "$BACKUP"

git tag -f pre-tools-v16 "$(git rev-parse HEAD)" 2>/dev/null || true

BOT_PY="$BOT_PY" python3 - <<'PYEOF'
import os, re, sys
from pathlib import Path

bot_py = Path(os.environ["BOT_PY"])
src = bot_py.read_text(encoding="utf-8")

if "ANALYTICAL_BYPASS v16" in src:
    print("ℹ️  v16 уже применён. Skip.")
    sys.exit(0)

# === 1. Inject _ANALYTICAL_QUERY_RE перед _CURRENCY_INTENT_RE ===
ANALYTICAL_RE = '''
# v16 ANALYTICAL_BYPASS 2026-05-18 — пропускать к LLM аналитические запросы
# о валюте/экономике (юзер хочет ОБЪЯСНЕНИЕ, не текущий курс).
_ANALYTICAL_QUERY_RE = re.compile(
    r"\\b(почему|чому|зачем|как\\s+так|из-за\\s+чего|по\\s+какой\\s+причине|"
    r"причин\\w+|тренд\\w*|прогноз\\w*|анализ\\w*|фактор\\w*|динамик\\w+|"
    r"объясни|расскажи|почему\\s+так|why|how\\s+come|reason|trend|forecast|analysis|"
    r"что\\s+влияет|какие\\s+причины|с\\s+чем\\s+связан\\w*|дешевеет|дорожает|растёт|падает|"
    r"рост|падение|обвал|укрепление|ослабление|девальвация|инфляция)",
    re.IGNORECASE,
)

'''

anchor = "_CURRENCY_INTENT_RE = re.compile("
pos = src.find(anchor)
if pos >= 0:
    src = src[:pos] + ANALYTICAL_RE + src[pos:]
    print("✅ _ANALYTICAL_QUERY_RE injected")
else:
    print("❌ _CURRENCY_INTENT_RE anchor не найден", file=sys.stderr)
    sys.exit(2)

# === 2. Update try_factual_intent_routing — guard analytical bypass ===
# Найти текущую implementation
m = re.search(r"def try_factual_intent_routing\(user_text: str\):", src)
if m:
    # Найти строку после docstring (первая строка кода)
    # Pattern: после ":" и docstring до first `if _CURRENCY_INTENT_RE`
    func_start = m.start()
    currency_check_pos = src.find("if _CURRENCY_INTENT_RE.search(user_text):", func_start)
    if currency_check_pos > 0:
        # Inject guard перед currency check
        guard = '''    # v16 ANALYTICAL_BYPASS — аналитические запросы (почему/как/прогноз/тренд)
    # должны идти в LLM с web_search для содержательного ответа, не в intercept.
    if _ANALYTICAL_QUERY_RE.search(user_text):
        return None

    '''
        src = src[:currency_check_pos] + guard + src[currency_check_pos:]
        print("✅ try_factual_intent_routing analytical bypass added")
    else:
        print("⚠️  _CURRENCY_INTENT_RE.search не найден", file=sys.stderr)
else:
    print("⚠️  try_factual_intent_routing не найден", file=sys.stderr)

# === 3. SYSTEM_PROMPT rule про аналитические запросы ===
ANALYTICAL_RULE = '''                "АНАЛИТИЧЕСКИЕ ЗАПРОСЫ О ВАЛЮТЕ/ЭКОНОМИКЕ (v16 ANALYTICAL_BYPASS 2026-05-18):\\n"
                "- Если юзер спрашивает «ПОЧЕМУ доллар дешевеет», «ПРИЧИНЫ роста евро», «КАК ТАК что рубль падает», «ТРЕНД USD», «ПРОГНОЗ EUR», «АНАЛИЗ инфляции» — это НЕ запрос текущего курса. Юзер хочет ОБЪЯСНЕНИЕ.\\n"
                "- В таких случаях НЕ отвечай одним числом курса. Иди в web_search за актуальной аналитикой (новости, факторы, контекст).\\n"
                "- Ответ должен включать: ключевые факторы (Fed policy / ECB / геополитика / commodity prices / risk sentiment / capital flows), временные рамки тренда, и опционально — текущее значение для контекста.\\n"
                "- Если web_search недоступен или нашёл противоречия — честно скажи «не могу дать актуальный анализ без свежих данных».\\n\\n"
'''

# Anchor — после anti-hallucination (v10) или security (v11)
anchors = [
    '"АНТИ-ГАЛЛЮЦИНАЦИЯ ФИНАНСОВЫХ ДАННЫХ (v10',
    '"ГЛОБАЛЬНОЕ ПРАВИЛО БЕЗОПАСНОСТИ (v11',
]
inserted = False
for anchor in anchors:
    pos = src.find(anchor)
    if pos < 0:
        continue
    line_end = src.find('\\n\\n"\n', pos)
    if line_end < 0:
        continue
    insert_pos = line_end + len('\\n\\n"\n')
    src = src[:insert_pos] + ANALYTICAL_RULE + src[insert_pos:]
    print(f"✅ Analytical rule injected после {anchor[:40]!r}")
    inserted = True
    break

if not inserted:
    print("⚠️  Analytical rule НЕ injected", file=sys.stderr)

bot_py.write_text(src, encoding="utf-8")
print(f"✅ bot.py updated. Size: {len(src)} chars.")
PYEOF

[ $? -ne 0 ] && { cp "$BACKUP" "$BOT_PY"; exit 4; }
python3 -m py_compile "$BOT_PY" || { cp "$BACKUP" "$BOT_PY"; exit 5; }
echo "✅ py_compile OK"

git add bot.py
git commit -m "fix(v16): аналитические запросы (почему/тренд/прогноз) — bypass intercept

Юра msg 17992 (2026-05-18): запрос 'почему доллар дешевеет во всем мире'
получил ответ '2.7535 BYN' — intercept перепутал analytical query с
factual rate request.

Fix:
1. _ANALYTICAL_QUERY_RE: маркеры почему/как/зачем/причина/тренд/прогноз/
   анализ/фактор/динамика/дешевеет/дорожает/растёт/падает/девальвация и т.д.
2. try_factual_intent_routing: если analytical match — return None
   (skip intercept → LLM сам обработает с web_search).
3. SYSTEM_PROMPT rule: аналитический запрос о валюте → НЕ число, а контекст
   (факторы, временные рамки, опц. текущее значение).

Backup tag: pre-tools-v16. Откат: git reset --hard pre-tools-v16." 2>&1 | tail -5

systemctl --user restart "$SERVICE" 2>&1 | tail -3
sleep 2

echo ""
echo "✅ v16 applied. Tests:"
echo "  «почему доллар дешевеет?» → LLM + web_search (объяснение)"
echo "  «прогноз евро на год» → LLM + web_search (range + uncertainty)"
echo "  «курс доллара сегодня» → intercept NBRB API (deterministic)"
echo "  «как там евро?» → analytical → LLM"
echo ""
echo "Откат: git reset --hard pre-tools-v16"
