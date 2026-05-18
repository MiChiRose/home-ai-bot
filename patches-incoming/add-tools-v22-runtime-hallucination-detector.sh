#!/usr/bin/env bash
# v22 — Юра msg 18053: runtime post-processing layer для детекции галлюцинаций.
#
# Это не prompt rule (это уже v10 для финансов + v21 общее правило), а
# реальный runtime detector в коде, который АНАЛИЗИРУЕТ LLM response ПЕРЕД
# отправкой юзеру и:
#   - Если detected hallucination → добавляет disclaimer ИЛИ перегенерирует
#
# Детекторы V1 (baseline, можно итеративно улучшать в v22b/v22c):
# 1. SPECIFIC_NUMBER_WITHOUT_TOOL: ответ содержит \d+[.,]\d+ числа, но в
#    этом турне не было tool calls (web_search / get_nbrb_rate / get_weather)
# 2. ANCHOR_WITHOUT_TOOL: ответ упоминает «по данным», «согласно сайту»,
#    «составляет», «получено», «по информации X» — без tool calls
# 3. TOPIC_DRIFT: jaccard similarity между user_text и response < 10%
#    AND response > 30 chars (не короткий small-talk)
#
# Действие при detection: добавить disclaimer в начале ответа:
# «⚠️ Возможна неточность — я не проверил это через интернет. Если нужны
# актуальные данные, попроси «перепроверь через web search».»

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
BOT_PY="$BOT_DIR/bot.py"
SERVICE="${SERVICE:-home-ai-bot.service}"

cd "$BOT_DIR"
[ ! -f "$BOT_PY" ] && { echo "❌ $BOT_PY не найден"; exit 1; }
python3 -m py_compile "$BOT_PY" || { echo "❌ bot.py УЖЕ broken"; exit 1; }

BACKUP="$BOT_DIR/bot.py.bak.before-tools-v22-$(date +%Y%m%d-%H%M%S)"
cp "$BOT_PY" "$BACKUP"
git tag -f pre-tools-v22 "$(git rev-parse HEAD)" 2>/dev/null || true

BOT_PY="$BOT_PY" python3 - <<'PYEOF'
import os, re, sys
from pathlib import Path

bot_py = Path(os.environ["BOT_PY"])
src = bot_py.read_text(encoding="utf-8")

if "RUNTIME_HALLUCINATION_DETECTOR v22" in src:
    print("ℹ️  v22 уже применён.")
    sys.exit(0)

# === Inject detector functions ===
DETECTOR_BLOCK = '''
# v22 RUNTIME_HALLUCINATION_DETECTOR 2026-05-18 — runtime post-processing
# layer для детекции возможных галлюцинаций LLM перед отправкой юзеру.

_HALLUCINATION_ANCHOR_RE = re.compile(
    r"(?i)\\b("
    r"по\\s+данным|согласно\\s+(?:сайту|данным|источнику|информации)|"
    r"источник[:\\s]|по\\s+информации|на\\s+момент\\s+\\d{4}|"
    r"составляет\\s+[\\d.,]+|равен\\s+[\\d.,]+|равняется|"
    r"получено\\s+через|by\\s+source|according\\s+to"
    r")\\b"
)

_SPECIFIC_NUMBER_RE = re.compile(r"\\b\\d+[.,]\\d+\\b")

_TRUSTED_TOOL_NAMES = {"web_search", "get_nbrb_rate", "get_gismeteo_weather",
                       "get_nbrb_rates_list", "read_file", "list_dir"}


def _tokens_for_similarity(text: str) -> set[str]:
    """Извлечь содержательные токены (>3 символа) для grouping similarity."""
    cleaned = re.sub(r"[^\\w\\s]", " ", text.lower())
    words = cleaned.split()
    stop = {"что", "как", "это", "был", "есть", "была", "была", "если",
            "его", "ему", "она", "они", "тоже", "тебе", "меня", "себя",
            "this", "that", "what", "have", "with"}
    return {w for w in words if len(w) > 3 and w not in stop}


def _detect_hallucination(
    user_text: str,
    response_text: str,
    tools_called: set | list | None = None,
) -> tuple[bool, str]:
    """v22: проверить ответ LLM на возможные галлюцинации.
    Returns (is_suspicious, reason)."""
    tools_called = set(tools_called) if tools_called else set()
    used_trusted = bool(tools_called & _TRUSTED_TOOL_NAMES)

    # Skip short small-talk responses
    if len(response_text.strip()) < 30:
        return (False, "short response — skip")

    # Detector 1: specific number without tool
    if not used_trusted and _SPECIFIC_NUMBER_RE.search(response_text):
        return (True, "specific number without tool call")

    # Detector 2: source anchor without tool
    if not used_trusted and _HALLUCINATION_ANCHOR_RE.search(response_text):
        return (True, "source anchor word without tool call")

    # Detector 3: topic drift (jaccard similarity < 10%)
    q_tokens = _tokens_for_similarity(user_text)
    r_tokens = _tokens_for_similarity(response_text)
    if q_tokens and r_tokens:
        intersection = q_tokens & r_tokens
        union = q_tokens | r_tokens
        if union:
            jaccard = len(intersection) / len(union)
            if jaccard < 0.05 and len(response_text) > 50:
                return (True, f"topic drift (jaccard={jaccard:.3f})")

    return (False, "ok")


def _add_hallucination_disclaimer(response_text: str, reason: str) -> str:
    """v22: добавить disclaimer в начало ответа если detected hallucination."""
    log.warning("hallucination flagged: %s -- response: %s", reason, response_text[:100])
    disclaimer = (
        "⚠️ Возможна неточность — я не проверил это через интернет. "
        "Если нужны актуальные данные, попроси «перепроверь через web search».\\n\\n"
    )
    return disclaimer + response_text


'''

# Inject перед try_factual_intent_routing (общая зона helpers)
anchor = "def try_factual_intent_routing("
pos = src.find(anchor)
if pos < 0:
    print("❌ try_factual_intent_routing anchor не найден", file=sys.stderr)
    sys.exit(2)
src = src[:pos] + DETECTOR_BLOCK + src[pos:]
print("✅ Detector functions injected")

# === Найти место в chat_handler где ответ готов, но ещё не отправлен ===
# Pattern: final_text = response_text.strip() or ...
final_pattern = re.compile(
    r'(final_text\s*=\s*response_text\.strip\(\)\s*or\s*"[^"]*")'
)
m = final_pattern.search(src)
if m:
    old_line = m.group(0)
    new_block = old_line + '''

        # v22 RUNTIME_HALLUCINATION_DETECTOR — post-process check
        try:
            # tool_calls_made — set имён tools которые были вызваны в этом турне.
            # В нашей системе chat_with_tools не возвращает list of tool calls,
            # поэтому грубое приближение: если ответ выглядит как deterministic
            # формат (содержит «BYN», «°C», «Курс ») — считаем что был intercept.
            tools_called = set()
            if any(marker in response_text for marker in ["BYN (на ", "°C", "Курс валют на", "ощущается как"]):
                tools_called.add("get_nbrb_rate")
            # web_search trace в нашем коде нет — но если ответ короткий, не суетимся.
            is_susp, reason = _detect_hallucination(user_text, final_text, tools_called)
            if is_susp:
                final_text = _add_hallucination_disclaimer(final_text, reason)
        except Exception as _exc:
            log.debug("hallucination detector skipped: %s", _exc)'''
    src = src.replace(old_line, new_block)
    print("✅ Detector hook вставлен после final_text assignment")
else:
    print("⚠️  final_text pattern не найден — manual injection нужен", file=sys.stderr)
    sys.exit(3)

bot_py.write_text(src, encoding="utf-8")
print(f"✅ bot.py updated. Size: {len(src)} chars.")
PYEOF

[ $? -ne 0 ] && { cp "$BACKUP" "$BOT_PY"; exit 4; }
python3 -m py_compile "$BOT_PY" || { cp "$BACKUP" "$BOT_PY"; exit 5; }
echo "✅ py_compile OK"

git add bot.py
git commit -m "feat(v22): runtime hallucination detector + auto-disclaimer

Юра msg 18053: глобальный обработчик галлюцинаций в runtime (не только
prompt rules).

Implementation:
1. _detect_hallucination(user_text, response, tools_called) — 3 детектора:
   - SPECIFIC_NUMBER_WITHOUT_TOOL: ответ содержит \\d+[.,]\\d+ без tool calls
   - SOURCE_ANCHOR_WITHOUT_TOOL: 'по данным', 'согласно сайту', 'составляет'
     без tool calls
   - TOPIC_DRIFT: jaccard similarity между user_text и response < 5%
2. _add_hallucination_disclaimer(response, reason) — добавляет disclaimer
   '⚠️ Возможна неточность...' в начало
3. Hook в chat_handler: после final_text assignment runs detector,
   если flagged — disclaimer применяется

V1 baseline: tools_called heuristic (формат deterministic ответов). В
будущем можно улучшить через явный возврат tool list из chat_with_tools.

Backup tag: pre-tools-v22. Откат: git reset --hard pre-tools-v22." 2>&1 | tail -5

systemctl --user restart "$SERVICE" 2>&1 | tail -3
sleep 2

echo ""
echo "✅ v22 applied. Tests:"
echo "  «курс доллара» → NBRB ответ (deterministic) → disclaimer НЕ добавится"
echo "  «расскажи факт про X» (LLM hallucinates) → если в ответе число → disclaimer"
echo "  «мем Окак» → если LLM уйдёт в погоду → topic drift → disclaimer"
echo ""
echo "Откат: git reset --hard pre-tools-v22"
echo ""
echo "False positives возможны — это V1. Если будут — пришли пример, я уточню regex'ы."
