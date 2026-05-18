#!/usr/bin/env bash
# add-tools-v6-remove-image-gen.sh
# Юра msg 17894 (2026-05-18) — выпилить генерацию картинок + hardcoded
# fallback со списком бесплатных сервисов.
#
# Changes:
# 1. chat_handler — early intercept на image-intent ДО LLM:
#    «К сожалению эта функция была удалена...» + hardcoded список 6 сайтов.
# 2. Auto-ship PNG из output_dir — выключен (был P3b ComfyUI integration).
# 3. _image_intent regex остаётся (нужен для intercept), _ship_png и
#    PNG auto-send удалены.
# 4. SYSTEM_PROMPT — добавлено: «генерацию картинок не делаю, отвечай
#    отказом + предложением сайтов».
#
# Voice STT — НЕ трогаем (рабочий tools/voice_stt + faster-whisper).
# Этот скрипт проверит import sanity для transcribe_voice — если упадёт,
# выведет warning (но не блокирует patch).

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
BOT_PY="$BOT_DIR/bot.py"
SERVICE="${SERVICE:-home-ai-bot.service}"

cd "$BOT_DIR"
[ ! -f "$BOT_PY" ] && { echo "❌ $BOT_PY не найден"; exit 1; }

echo "==> BOT_DIR: $BOT_DIR"
echo "==> bot.py: $(wc -l < "$BOT_PY") строк"

BACKUP="$BOT_DIR/bot.py.bak.before-tools-v6-$(date +%Y%m%d-%H%M%S)"
cp "$BOT_PY" "$BACKUP"
echo "✅ backup: $BACKUP"

git tag -f pre-tools-v6 "$(git rev-parse HEAD)" 2>/dev/null || true

# ====================================================================
# Voice STT sanity check — non-blocking
# ====================================================================
echo ""
echo "==> Voice STT sanity check"
python3 -c "
import sys
sys.path.insert(0, '$BOT_DIR')
try:
    from tools.voice_stt import transcribe_voice
    print('✅ transcribe_voice import OK')
except ImportError as e:
    print(f'⚠️ transcribe_voice import FAILED: {e}')
    print('   Voice STT может не работать. Проверь tools/voice_stt.py и faster_whisper в venv.')
except Exception as e:
    print(f'⚠️ transcribe_voice проверка: {e}')
" 2>&1 || echo "⚠️ Voice check warning (non-blocking)"

# ====================================================================
# Apply patches via Python
# ====================================================================
BOT_PY="$BOT_PY" python3 - <<'PYEOF'
import os
import re
import sys
from pathlib import Path

bot_py = Path(os.environ["BOT_PY"])
src = bot_py.read_text(encoding="utf-8")

# Idempotency guard
if "IMAGE_GEN_REMOVED v6" in src:
    print("ℹ️  v6 уже применён. Skip.")
    sys.exit(0)

# ====================================================================
# 1. Inject image-intent early intercept в chat_handler ПОСЛЕ factual_intent_routing
# ====================================================================
ANCHOR = '''        if early_answer:
            await msg.answer(early_answer)
            await _react(msg, "🎉")
            return
'''

IMAGE_INTERCEPT = '''
    # v6 (2026-05-18) — IMAGE_GEN_REMOVED: ranged hardcoded refusal.
    # Если юзер просит сгенерировать/нарисовать картинку — отказ + список сайтов.
    if user_text and not has_image and not has_voice and not msg.document:
        import re as _re_v6
        _img_intent_re = _re_v6.compile(
            r"(?i)(\\bкартинк\\w+|\\bизображени\\w+|\\bрисунок\\w*|\\bphoto\\b|\\bimage\\b|\\bрендер\\w*|\\bсгенерируй|\\bнарисуй|\\bdraw\\b|\\bgenerate.*image)"
        )
        if _img_intent_re.search(user_text):
            await msg.answer(
                "К сожалению, функция генерации картинок была удалена за ненадобностью.\\n\\n"
                "Но могу подсказать бесплатные сервисы, где можно сгенерировать изображения:\\n\\n"
                "1. <b>Bing Image Creator</b> — https://www.bing.com/create (DALL-E 3, бесплатно)\\n"
                "2. <b>Ideogram</b> — https://ideogram.ai (хорошо с текстом на картинках, 25/день free)\\n"
                "3. <b>Leonardo AI</b> — https://leonardo.ai (150 credits/день free)\\n"
                "4. <b>Krea AI</b> — https://krea.ai (real-time generation, free tier)\\n"
                "5. <b>Microsoft Designer</b> — https://designer.microsoft.com (free)\\n"
                "6. <b>Playground AI</b> — https://playground.com (1000 images/день free)",
                parse_mode="HTML",
                disable_web_page_preview=True,
            )
            await _react(msg, "🎉")
            return

'''

if ANCHOR in src:
    src = src.replace(ANCHOR, ANCHOR + IMAGE_INTERCEPT, 1)
    print("✅ Image-intent intercept injected в chat_handler")
else:
    print("❌ Anchor (early_answer return) не найден.", file=sys.stderr)
    sys.exit(2)

# ====================================================================
# 2. Disable PNG auto-ship in output_dir handling
# Заменяем `if not _ship_png: pass / else: for png ... ` на «всегда skip»
# ====================================================================
png_pattern = re.compile(
    r"# P3b: image auto-send — сгенерированные PNG из ComfyUI\n"
    r"                if not _ship_png:\n"
    r"                  pass  # auto-ship skipped, см\. guard выше\n"
    r"                else:\n"
    r"                  for png_file in output_dir\.glob\(\"\*\.png\"\):\n"
    r"                    if time\.time\(\) - png_file\.stat\(\)\.st_mtime < 60:\n"
    r"                        try:\n"
    r"                            await msg\.answer_photo\(_FSInputFile\(str\(png_file\)\)\)\n"
    r"                            log\.info\(\"sent png to user: %s\", png_file\)\n"
    r"                        except Exception as e:\n"
    r"                            log\.warning\(\"send png failed: %s\", e\)\n",
    re.MULTILINE,
)

png_replacement = '''# P3b: IMAGE_GEN_REMOVED v6 (2026-05-18) — PNG auto-ship выключен.
                # Генерация картинок через ComfyUI больше не доступна.
                # Если юзер reaches до этой ветки и output_dir/*.png существует —
                # это stale файл, не отправляем.
                pass
'''

if png_pattern.search(src):
    src = png_pattern.sub(png_replacement, src)
    print("✅ PNG auto-ship disabled в output_dir handling")
else:
    print("⚠️  PNG auto-ship pattern не найден — возможно структура другая. Manual review нужен.")

# ====================================================================
# 3. SYSTEM_PROMPT — добавить rule про image gen
# ====================================================================
SP_INSERT = '''                "ГЕНЕРАЦИЯ КАРТИНОК ОТСУТСТВУЕТ (v6 2026-05-18):\\n"
                "- Ты НЕ умеешь генерировать изображения. ComfyUI/Stable Diffusion/DALL-E недоступны.\\n"
                "- Запросы на «нарисуй/сгенерируй/создай картинку» уже перехвачены до тебя — но если каким-то образом долетели, отвечай что эта функция была удалена за ненадобностью, и предложи альтернативу (Bing Image Creator, Ideogram, Leonardo).\\n"
                "- НЕ обещай нарисовать. НЕ говори «сейчас сгенерирую». Сразу отказ + альтернатива.\\n\\n"
'''

# Anchor — после SMALL-TALK блока (последний "Не на каждое сообщение.\\n\\n")
sp_anchor = '"- web_search вызывай ТОЛЬКО когда юзер реально просит факт'
if sp_anchor in src:
    line_end = src.find('\\n\\n"\n', src.find(sp_anchor))
    if line_end > 0:
        insert_pos = line_end + len('\\n\\n"\n')
        if "ГЕНЕРАЦИЯ КАРТИНОК ОТСУТСТВУЕТ" not in src:
            src = src[:insert_pos] + SP_INSERT + src[insert_pos:]
            print("✅ SYSTEM_PROMPT image-gen rule injected")
        else:
            print("ℹ️  SYSTEM_PROMPT image-gen rule уже есть")
    else:
        print("⚠️  SMALL-TALK конец не найден — SYSTEM_PROMPT image-gen rule skip")
else:
    print("⚠️  SMALL-TALK anchor не найден — SYSTEM_PROMPT image-gen rule skip")

# ====================================================================
# 4. Fix error reporter: ADMIN_USER_IDS → ADMIN_IDS (root cause why no alerts)
# ====================================================================
if "_admins = list(ADMIN_USER_IDS)" in src:
    src = src.replace(
        "_admins = list(ADMIN_USER_IDS)  # type: ignore[name-defined]",
        "_admins = list(ADMIN_IDS)  # v6 fix: было ADMIN_USER_IDS (NameError → _admins=[] → no alerts)",
    )
    print("✅ Error reporter ADMIN_USER_IDS → ADMIN_IDS fix applied")
else:
    print("ℹ️  Error reporter уже патчен или сигнатура другая")

# ====================================================================
# Marker для idempotency
# ====================================================================
if "# IMAGE_GEN_REMOVED v6 (2026-05-18)" not in src:
    src = src.replace(
        "# ============================================================\n# main",
        "# IMAGE_GEN_REMOVED v6 (2026-05-18) — генерация картинок выпилена\n"
        "# (см. chat_handler image-intent early intercept + SYSTEM_PROMPT rule)\n\n"
        "# ============================================================\n# main",
        1,
    )

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
git commit -m "feat(v6): выпилить генерацию картинок + hardcoded fallback со списком сервисов

Юра msg 17894 (2026-05-18) — функция генерации изображений признана
ненужной и нагружающей бота.

Changes:
1. chat_handler — image-intent early intercept ДО LLM:
   regex match (\"нарисуй/сгенерируй/картинка/draw/generate image\")
   → hardcoded отказ + 6 бесплатных сервисов:
   Bing Image Creator, Ideogram, Leonardo AI, Krea AI,
   Microsoft Designer, Playground AI.

2. PNG auto-ship из output_dir выключен.
   P3b ComfyUI integration отключён (stale files больше не отправляются).

3. SYSTEM_PROMPT rule: ГЕНЕРАЦИЯ КАРТИНОК ОТСУТСТВУЕТ.
   Запрет на «сейчас сгенерирую», обязательный отказ + альтернатива.

Voice STT (tools/voice_stt + faster-whisper) — НЕ тронут.
Sanity check transcribe_voice import выполнен перед патчем.

4. ERROR REPORTER FIX (root cause):
   ADMIN_USER_IDS → ADMIN_IDS. Юра жаловался msg 17898 что ошибки не
   прилетают. Старый код: 'list(ADMIN_USER_IDS)' → NameError →
   '_admins = []' → никому не шлёт. Фикс: ADMIN_IDS (реальное имя set).

Backup tag: pre-tools-v6. Откат: git reset --hard pre-tools-v6." 2>&1 | tail -5

echo ""
echo "==> restart $SERVICE"
systemctl --user restart "$SERVICE" 2>&1 | tail -3
sleep 2
systemctl --user status "$SERVICE" --no-pager 2>&1 | head -8

echo ""
echo "✅ v6 applied. Tests:"
echo "  «нарисуй собаку» → hardcoded refusal + список 6 сервисов"
echo "  «сгенерируй картинку» → тот же refusal"
echo "  voice msg → должно работать (STT не тронут)"
echo ""
echo "Откат:"
echo "  git reset --hard pre-tools-v6"
echo "  cp '$BACKUP' '$BOT_PY'"
echo "  systemctl --user restart $SERVICE"
