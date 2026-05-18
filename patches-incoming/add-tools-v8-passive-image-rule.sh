#!/usr/bin/env bash
# add-tools-v8-passive-image-rule.sh
# Юра msg 17918 (2026-05-18): бот «с того ни с сего» сказал что не умеет
# генерировать изображения. Side effect v6 SYSTEM_PROMPT rule — LLM стала
# проактивно упоминать ограничение.
#
# Fix: сделать rule **пассивным** — не упоминать функцию пока не спросят.
# Intercept (regex matcher в chat_handler) уже handles запросы — LLM не
# должна сама подсвечивать ограничение.

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
BOT_PY="$BOT_DIR/bot.py"
SERVICE="${SERVICE:-home-ai-bot.service}"

cd "$BOT_DIR"
[ ! -f "$BOT_PY" ] && { echo "❌ $BOT_PY не найден"; exit 1; }

BACKUP="$BOT_DIR/bot.py.bak.before-tools-v8-$(date +%Y%m%d-%H%M%S)"
cp "$BOT_PY" "$BACKUP"
echo "✅ backup: $BACKUP"

git tag -f pre-tools-v8 "$(git rev-parse HEAD)" 2>/dev/null || true

BOT_PY="$BOT_PY" python3 - <<'PYEOF'
import os, sys
from pathlib import Path

bot_py = Path(os.environ["BOT_PY"])
src = bot_py.read_text(encoding="utf-8")

if "PASSIVE_IMAGE_RULE v8" in src:
    print("ℹ️  v8 уже применён. Skip.")
    sys.exit(0)

OLD_BLOCK = '''                "ГЕНЕРАЦИЯ КАРТИНОК ОТСУТСТВУЕТ (v6 2026-05-18):\\n"
                "- Ты НЕ умеешь генерировать изображения. ComfyUI/Stable Diffusion/DALL-E недоступны.\\n"
                "- Запросы на «нарисуй/сгенерируй/создай картинку» уже перехвачены до тебя — но если каким-то образом долетели, отвечай что эта функция была удалена за ненадобностью, и предложи альтернативу (Bing Image Creator, Ideogram, Leonardo).\\n"
                "- НЕ обещай нарисовать. НЕ говори «сейчас сгенерирую». Сразу отказ + альтернатива.\\n\\n"'''

NEW_BLOCK = '''                "ГЕНЕРАЦИЯ КАРТИНОК — ПАССИВНОЕ ПРАВИЛО (v8 PASSIVE_IMAGE_RULE 2026-05-18):\\n"
                "- НЕ упоминай ничего про генерацию изображений, ComfyUI, Stable Diffusion, DALL-E пока пользователь явно не попросил нарисовать/сгенерировать.\\n"
                "- НЕ предупреждай заранее, не пиши «я не умею» по своей инициативе. Это создаёт шум — система уже перехватывает запросы про картинки автоматически.\\n"
                "- НЕ обещай нарисовать. НЕ говори «сейчас сгенерирую».\\n"
                "- Молчи про эту тему. Просто отвечай на то, что юзер реально спросил.\\n\\n"'''

if OLD_BLOCK in src:
    src = src.replace(OLD_BLOCK, NEW_BLOCK)
    print("✅ Image rule переведён в пассивный режим")
else:
    print("⚠️  v6 image rule не найден — возможно структура изменилась", file=sys.stderr)
    sys.exit(2)

bot_py.write_text(src, encoding="utf-8")
print(f"✅ bot.py updated. Size: {len(src)} chars.")
PYEOF

[ $? -ne 0 ] && {
    echo "❌ Python error. Восстанавливаю backup..."
    cp "$BACKUP" "$BOT_PY"
    exit 4
}

python3 -m py_compile "$BOT_PY" || {
    cp "$BACKUP" "$BOT_PY"
    exit 5
}
echo "✅ py_compile OK"

git add bot.py
git commit -m "fix(v8): переключить image-gen rule в пассивный режим

Юра msg 17918 (2026-05-18) — бот проактивно упоминал отсутствие генерации
картинок без запроса пользователя.

Root cause: v6 SYSTEM_PROMPT правило формулировало 'если спросят — отказ'
+ перечисляло альтернативы, что побуждало LLM упоминать тему сама.

Fix: rule переписан как ПАССИВНЫЙ — 'молчи про эту тему, intercept уже
handles, не пиши <я не умею> по своей инициативе'.

Backup tag: pre-tools-v8. Откат: git reset --hard pre-tools-v8." 2>&1 | tail -5

systemctl --user restart "$SERVICE" 2>&1 | tail -3
sleep 2
systemctl --user status "$SERVICE" --no-pager 2>&1 | head -6

echo ""
echo "✅ v8 applied."
echo "  «как дела» → small-talk без упоминания image-gen"
echo "  «расскажи про кота» → ответ без 'я не умею рисовать'"
echo "  «нарисуй кота» → всё ещё intercept'ится hardcoded refusal'ом"
echo ""
echo "Откат: git reset --hard pre-tools-v8"
