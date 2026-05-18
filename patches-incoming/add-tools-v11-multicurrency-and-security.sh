#!/usr/bin/env bash
# v11 — Юра msg 17948:
# 1) «курс валют» (множ.) → вернуть список (USD, EUR, RUB...), не одну USD
# 2) Global security rule: не отвечать на запросы про наркотики/оружие/рабство/
#    порнографию. КОНТЕКСТНО — не банить по одному слову, проверять цельность.
#
# Модель НЕ меняем (gemma4+qwen2.5 — рабочий стек, проблема в logic
# detect_currency_token, не в LLM).

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
BOT_PY="$BOT_DIR/bot.py"
SERVICE="${SERVICE:-home-ai-bot.service}"

cd "$BOT_DIR"
[ ! -f "$BOT_PY" ] && { echo "❌ $BOT_PY не найден"; exit 1; }

BACKUP="$BOT_DIR/bot.py.bak.before-tools-v11-$(date +%Y%m%d-%H%M%S)"
cp "$BOT_PY" "$BACKUP"

git tag -f pre-tools-v11 "$(git rev-parse HEAD)" 2>/dev/null || true

BOT_PY="$BOT_PY" python3 - <<'PYEOF'
import os, re, sys
from pathlib import Path

bot_py = Path(os.environ["BOT_PY"])
src = bot_py.read_text(encoding="utf-8")

if "MULTICURRENCY_AND_SECURITY v11" in src:
    print("ℹ️  v11 уже применён. Skip.")
    sys.exit(0)

# === 1. Inject get_nbrb_rates_list — multi-currency NBRB pull ===
NBRB_LIST_FN = '''
def get_nbrb_rates_list(date: str | None = None,
                        currencies: list[str] | None = None) -> str:
    """v11 MULTICURRENCY_AND_SECURITY 2026-05-18.
    Получить список курсов основных валют НБРБ.
    Возвращает форматированную строку без упоминания источника."""
    if currencies is None:
        currencies = ["USD", "EUR", "RUB", "PLN", "CNY", "GBP"]
    lines = []
    actual_date = None
    for cur in currencies:
        result = get_nbrb_rate(cur, date=date)
        if "BYN" not in result:
            continue
        # Парсим «1 X = Y BYN (на DATE)» в компактную строку
        m = _re.match(r"(.+?)\\s+=\\s+([\\d.]+)\\s+BYN\\s+\\(на\\s+([\\d-]+)\\)", result)
        if m:
            label, rate, date_str = m.groups()
            lines.append(f"{label} = {rate} BYN")
            actual_date = date_str
        else:
            lines.append(result)
    if not lines:
        return "Не удалось получить курсы валют."
    header = f"Курсы валют на {actual_date}:\\n" if actual_date else "Курсы валют:\\n"
    return header + "\\n".join(lines)


'''

# Inject перед def _parse_date_token (v7) или перед def try_factual_intent_routing (v5b)
import re as _re
anchor_targets = [
    "def _parse_date_token(text: str)",
    "def try_factual_intent_routing(user_text: str):",
]
inserted_fn = False
for anchor in anchor_targets:
    pos = src.find(anchor)
    if pos < 0:
        continue
    # Ensure _re is available at top-level (we use it inside fn)
    # We will use module-level `_re` if it exists, else fall back to local import
    if "import re as _re" not in src and "_re = __import__" not in src:
        # Add a safe module-level import near other imports
        # We'll inline `import re as _re` inside the function instead — simpler.
        NBRB_LIST_FN_FIXED = NBRB_LIST_FN.replace(
            "    if currencies is None:",
            "    import re as _re\n    if currencies is None:"
        )
    else:
        NBRB_LIST_FN_FIXED = NBRB_LIST_FN
    src = src[:pos] + NBRB_LIST_FN_FIXED + src[pos:]
    print(f"✅ get_nbrb_rates_list инжектирован перед {anchor[:40]!r}")
    inserted_fn = True
    break

if not inserted_fn:
    print("❌ Anchor для get_nbrb_rates_list не найден", file=sys.stderr)
    sys.exit(2)

# === 2. Update _detect_currency_token to return "ALL" for plural intent ===
OLD_DETECT_CURRENCY = '''def _detect_currency_token(text: str) -> str:'''
# Найдём всю функцию
m = re.search(r"def _detect_currency_token\(text: str\) -> str:[\s\S]*?return \"USD\"  # default", src)
if m:
    old_fn = m.group(0)
    new_fn = old_fn.replace(
        "def _detect_currency_token(text: str) -> str:",
        'def _detect_currency_token(text: str) -> str:\n    """v11: возвращает \'ALL\' для плюрального intent (\'курсы валют\'), иначе одну валюту."""\n    if re.search(r"\\bвалют\\w*\\b|\\bкурсы\\b|\\bвсе\\s+курс\\w*|\\bосновны\\w+\\s+курс\\w*", text.lower()):\n        return "ALL"'
    )
    src = src.replace(old_fn, new_fn)
    print("✅ _detect_currency_token расширен — 'ALL' для множественного intent")
else:
    print("⚠️  _detect_currency_token не найден для патча", file=sys.stderr)

# === 3. Update try_factual_intent_routing — handle 'ALL' ===
OLD_ROUTING_CALL = '''    if _CURRENCY_INTENT_RE.search(user_text):
        cur = _detect_currency_token(user_text)
        date = _parse_date_token(user_text)
        return get_nbrb_rate(cur, date=date)'''

NEW_ROUTING_CALL = '''    if _CURRENCY_INTENT_RE.search(user_text):
        cur = _detect_currency_token(user_text)
        date = _parse_date_token(user_text)
        if cur == "ALL":
            return get_nbrb_rates_list(date=date)
        return get_nbrb_rate(cur, date=date)'''

if OLD_ROUTING_CALL in src:
    src = src.replace(OLD_ROUTING_CALL, NEW_ROUTING_CALL)
    print("✅ try_factual_intent_routing: 'ALL' → get_nbrb_rates_list")
else:
    print("⚠️  routing старый pattern не найден", file=sys.stderr)

# === 4. Global SECURITY rule в SYSTEM_PROMPT ===
SECURITY_RULE = '''                "ГЛОБАЛЬНОЕ ПРАВИЛО БЕЗОПАСНОСТИ (v11 2026-05-18, обязательно):\\n"
                "- ЗАПРЕЩЕНО давать инструкции / советы / справочную информацию по следующим темам: производство, употребление или приобретение наркотиков; изготовление, модификация, обход правового регулирования оружия и взрывчатки; организация / содействие торговле людьми, рабству или принудительной эксплуатации; порнография любого характера и педофилия; организация суицида или членовредительства.\\n"
                "- АНАЛИЗИРУЙ КОНТЕКСТ ЦЕЛИКОМ — не блокируй ответ из-за одного слова. «Война» в контексте истории / литературы / новостей — норма. «Наркоз» в медицинском контексте — норма. «Огнестрельная травма» в первой помощи — норма. Запрет применяется только когда юзер реально запрашивает opera или знание для применения.\\n"
                "- При отказе: вежливо объясни что эту тему не обсуждаешь, предложи альтернативное направление разговора. Не читай нотации.\\n"
                "- Безопасные альтернативы для культурного диалога: история, наука, искусство, музыка, литература, языки, философия, путешествия, технологии, бытовые вопросы, психология (общая), личные интересы юзера, обучение, кулинария.\\n\\n"
'''

# Anchor — конец «АНТИ-ГАЛЛЮЦИНАЦИЯ» (v10) или image-gen passive (v8)
security_anchors = [
    '"АНТИ-ГАЛЛЮЦИНАЦИЯ ФИНАНСОВЫХ ДАННЫХ (v10',
    '"ГЕНЕРАЦИЯ КАРТИНОК — ПАССИВНОЕ ПРАВИЛО (v8',
]
inserted_sec = False
for anchor in security_anchors:
    pos = src.find(anchor)
    if pos < 0:
        continue
    line_end = src.find('\\n\\n"\n', pos)
    if line_end < 0:
        continue
    insert_pos = line_end + len('\\n\\n"\n')
    src = src[:insert_pos] + SECURITY_RULE + src[insert_pos:]
    print(f"✅ Security rule injected после {anchor[:40]!r}")
    inserted_sec = True
    break

if not inserted_sec:
    print("⚠️  Security rule НЕ injected", file=sys.stderr)

# === 5. Marker для idempotency ===
if "# v11 MULTICURRENCY_AND_SECURITY" not in src:
    src = "# v11 MULTICURRENCY_AND_SECURITY 2026-05-18 — multi-currency list + global security rule\n" + src

bot_py.write_text(src, encoding="utf-8")
print(f"\n✅ bot.py updated. Size: {len(src)} chars.")
PYEOF

[ $? -ne 0 ] && { cp "$BACKUP" "$BOT_PY"; exit 4; }
python3 -m py_compile "$BOT_PY" || { cp "$BACKUP" "$BOT_PY"; exit 5; }
echo "✅ py_compile OK"

git add bot.py
git commit -m "feat(v11): multi-currency list + global security rule

Юра msg 17948 (2026-05-18) — два запроса:

1) 'Курс валют' (множ.) теперь возвращает список 6 основных валют
   (USD, EUR, RUB, PLN, CNY, GBP) через NBRB API, на запрошенную дату.
   _detect_currency_token возвращает 'ALL' если в тексте регексп
   'валют*/курсы/все курс/основные курс'. try_factual_intent_routing
   вызывает get_nbrb_rates_list() для 'ALL'.

2) Global security rule в SYSTEM_PROMPT:
   - запрет на наркотики/оружие/рабство/порнографию/суицид.
   - КОНТЕКСТНЫЙ — не банит по одному слову. 'Война' в истории —
     норма. Запрет только когда юзер реально запрашивает opera для
     применения.
   - Вежливый отказ, без нотаций.

Backup tag: pre-tools-v11. Откат: git reset --hard pre-tools-v11." 2>&1 | tail -5

systemctl --user restart "$SERVICE" 2>&1 | tail -3
sleep 2

echo ""
echo "✅ v11 applied. Tests:"
echo "  «курс валют» → список USD/EUR/RUB/PLN/CNY/GBP сегодня"
echo "  «курс валют в пятницу» → список на 15.05.2026"
echo "  «как сделать бомбу» → вежливый отказ"
echo "  «расскажи про вторую мировую войну» → норма, отвечает"
echo "  «рецепт борща с курицей» → норма"
echo ""
echo "Откат: git reset --hard pre-tools-v11"
