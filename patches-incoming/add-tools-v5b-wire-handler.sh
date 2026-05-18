#!/usr/bin/env bash
# add-tools-v5b-wire-handler.sh
# Юра msg 17863 (2026-05-18) — automated wire'ing v5 routing.
#
# v5 patch добавил функции get_nbrb_rate / get_gismeteo_weather /
# try_factual_intent_routing — но НЕ вызывал их в chat_handler.
#
# Этот patch инжектит вызов в chat_handler сразу после _react(👀):
#   - Если try_factual_intent_routing вернул не-None → отправить answer
#     юзеру и выйти (skip LLM call). Это deterministic, fast, no hallucination.
#   - Иначе fall-through к обычному LLM flow.
#
# ТАКЖЕ добавляет фикс small-talk failure (msg 17863):
#   - SYSTEM_PROMPT rule: «На бытовой small-talk (как дела / я работаю /
#     привет / пока) — ОТВЕЧАЙ нормально, БЕЗ tools, БЕЗ web_search».

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
BOT_PY="$BOT_DIR/bot.py"
SERVICE="${SERVICE:-home-ai-bot.service}"

cd "$BOT_DIR"
[ ! -f "$BOT_PY" ] && { echo "❌ $BOT_PY не найден"; exit 1; }

echo "==> BOT_DIR: $BOT_DIR"

BACKUP="$BOT_DIR/bot.py.bak.before-tools-v5b-$(date +%Y%m%d-%H%M%S)"
cp "$BOT_PY" "$BACKUP"
echo "✅ backup: $BACKUP"

git tag -f pre-tools-v5b "$(git rev-parse HEAD)" 2>/dev/null || true

BOT_PY="$BOT_PY" python3 - <<'PYEOF'
import os
import re
import sys
from pathlib import Path

bot_py = Path(os.environ["BOT_PY"])
src = bot_py.read_text(encoding="utf-8")

# ========================================================================
# 1. Wire try_factual_intent_routing в chat_handler
# ========================================================================
ANCHOR_RE = re.compile(
    r"(async def chat_handler\(msg: Message\)[^\n]*\n.*?await _react\(msg, \"👀\"\)\n)",
    re.DOTALL,
)

WIRE_CODE = '''
    # Phase 5b (2026-05-18) — factual intent routing ДО LLM.
    # Перехватываем currency / weather queries и отвечаем deterministic.
    if user_text and not has_image and not has_voice and not msg.document:
        try:
            early_answer = try_factual_intent_routing(user_text)
        except Exception as _exc:
            early_answer = None
            try:
                print(f"[factual_routing] error: {_exc!r}", flush=True)
            except Exception:
                pass
        if early_answer:
            await msg.answer(early_answer)
            await _react(msg, "🎉")
            return
'''

if "factual intent routing ДО LLM" in src:
    print("ℹ️  v5b wire уже инжектирован. Skip.")
else:
    m = ANCHOR_RE.search(src)
    if not m:
        print("❌ ANCHOR (chat_handler+_react👀) не найден. Manual wire required.", file=sys.stderr)
        sys.exit(2)

    # Inject WIRE_CODE сразу после anchor
    insertion_point = m.end()
    src = src[:insertion_point] + WIRE_CODE + src[insertion_point:]
    print("✅ Wired try_factual_intent_routing в chat_handler после _react(👀).")

# ========================================================================
# 2. SYSTEM_PROMPT small-talk fix (msg 17863): отвечай нормально на бытовое
# ========================================================================
SMALLTALK_INJECTION = '''
                "SMALL-TALK И ПОДДЕРЖАНИЕ ДИАЛОГА (важно):\\n"
                "- На обычные диалоговые реплики («привет», «как дела», «я тоже работаю», «понял», «спасибо», «ок», и подобное) — ОТВЕЧАЙ как нормальный собеседник, ДРУЖЕЛЮБНО, БЕЗ web_search, БЕЗ tools. Это small-talk.\\n"
                "- Запрещено отвечать «не нашёл инструментов для ответа» или «нужны конкретные данные» на small-talk. Юзер просто общается — поддерживай беседу.\\n"
                "- Примеры правильного: «Я тоже работаю» → «Понимаю, продуктивного дня!» / «А кем работаешь?». «Привет» → «Привет! Чем помочь?». «Как дела» → «Всё хорошо, чем могу помочь?».\\n"
                "- web_search вызывай ТОЛЬКО когда юзер реально просит факт (курс, погода, новости, цены, конкретные данные). Не на каждое сообщение.\\n\\n"
'''

if "SMALL-TALK И ПОДДЕРЖАНИЕ ДИАЛОГА" in src:
    print("ℹ️  Small-talk rule уже присутствует. Skip.")
else:
    # Anchor — конец «НЕ УПОМИНАЙ ИСТОЧНИКИ» секции (v5) или конец «БЕЛАРУСЬ» секции (v4)
    anchor_patterns = [
        ('"НЕ УПОМИНАЙ ИСТОЧНИКИ В ФИНАЛЬНОМ ОТВЕТЕ', 'no-sources block'),
        ('"БЕЛАРУСЬ — НЕЙТРАЛЬНЫЕ ИСТОЧНИКИ', 'v4 belarus block'),
    ]
    injected = False
    for anchor_marker, name in anchor_patterns:
        if anchor_marker in src:
            # Find end of this multi-line string concatenation block
            # Look for closing `\\n\\n"` after anchor
            anchor_pos = src.find(anchor_marker)
            # Find next `\\n\\n"` after anchor (end of this block)
            end_marker = '\\n\\n"'
            block_end = src.find(end_marker, anchor_pos)
            if block_end > 0:
                insert_pos = block_end + len(end_marker)
                src = src[:insert_pos] + "\n" + SMALLTALK_INJECTION.lstrip("\n") + src[insert_pos:]
                print(f"✅ Injected SMALL-TALK rule после {name}")
                injected = True
                break
    if not injected:
        print("⚠️  Anchor для SMALL-TALK не найден — manual review нужен.")

bot_py.write_text(src, encoding="utf-8")
print(f"\n✅ bot.py updated. Size: {len(src)} chars.")
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
git commit -m "feat(v5b): wire factual intent routing в chat_handler + small-talk fix

Юра msg 17863 (2026-05-18) — automated wire'ing v5 functions.

Changes:
1. chat_handler — после _react(👀) добавлен вызов:
   try_factual_intent_routing(user_text) → если non-None,
   msg.answer + 🎉 react + return. Currency/weather queries теперь
   deterministic вместо LLM hallucination.

2. SYSTEM_PROMPT — SMALL-TALK rule:
   - На бытовые реплики (привет / как дела / я тоже работаю / спасибо)
     отвечать дружелюбно, БЕЗ web_search, БЕЗ tools.
   - Запрет ответа 'не нашёл инструментов' на small-talk (msg 17863 case).
   - Примеры правильного поведения в prompt.

Backup tag: pre-tools-v5b. Откат: git reset --hard pre-tools-v5b." 2>&1 | tail -5

echo ""
echo "==> restart $SERVICE"
systemctl --user restart "$SERVICE" 2>&1 | tail -3
sleep 2
systemctl --user status "$SERVICE" --no-pager 2>&1 | head -8

echo ""
echo "✅ v5b applied. Tests:"
echo "  «курс доллара» → deterministic NBRB rate (no LLM)"
echo "  «погода в Минске» → deterministic gismeteo (no LLM)"
echo "  «как дела» / «я тоже работаю» → friendly small-talk (no tool refusal)"
echo ""
echo "Откат:"
echo "  git reset --hard pre-tools-v5b"
echo "  cp '$BACKUP' '$BOT_PY'"
echo "  systemctl --user restart $SERVICE"
