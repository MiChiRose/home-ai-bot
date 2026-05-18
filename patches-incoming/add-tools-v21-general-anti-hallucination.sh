#!/usr/bin/env bash
# v21 — Юра msg 18041: бот на вопрос «Ты знаешь мем "Окак"?» ответил про
# погоду в Минске.
#
# Root cause: qwen2.5:7b НЕ знает мем «Окак» (это рунет-мем, Telegram/VK
# культура, не в global training). Вместо честного «не знаю» small model
# уходит в ближайший знакомый pattern из SYSTEM_PROMPT — где упоминается
# Минск/погода/gismeteo несколько раз. Это classic small-LLM hallucination.
#
# Fix: общее anti-hallucination правило (расширение v10 для финансов
# на ВСЕ домены). Phrase: «если не знаешь — говори "не знаю", не выдумывай».

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
BOT_PY="$BOT_DIR/bot.py"
SERVICE="${SERVICE:-home-ai-bot.service}"

cd "$BOT_DIR"
[ ! -f "$BOT_PY" ] && { echo "❌ $BOT_PY не найден"; exit 1; }

python3 -m py_compile "$BOT_PY" || { echo "❌ bot.py УЖЕ broken"; exit 1; }

BACKUP="$BOT_DIR/bot.py.bak.before-tools-v21-$(date +%Y%m%d-%H%M%S)"
cp "$BOT_PY" "$BACKUP"
git tag -f pre-tools-v21 "$(git rev-parse HEAD)" 2>/dev/null || true

BOT_PY="$BOT_PY" python3 - <<'PYEOF'
import os, sys
from pathlib import Path

bot_py = Path(os.environ["BOT_PY"])
src = bot_py.read_text(encoding="utf-8")

if "GENERAL_ANTI_HALLUCINATION v21" in src:
    print("ℹ️  v21 уже применён.")
    sys.exit(0)

GENERAL_AH_RULE = '''                "ОБЩЕЕ АНТИ-ГАЛЛЮЦИНАЦИОННОЕ ПРАВИЛО (v21 GENERAL_ANTI_HALLUCINATION 2026-05-18, ВАЖНО):\\n"
                "- ЕСЛИ ТЫ НЕ ЗНАЕШЬ ответа на вопрос — скажи «не знаю» / «не знаком с этим» / «не нашёл информации». ЭТО НОРМАЛЬНО.\\n"
                "- ЗАПРЕЩЕНО выдумывать ответ или подменять тему на что-то знакомое. Если юзер спросил про X, а ты знаешь только про Y — НЕ отвечай про Y. Скажи что не знаком с X.\\n"
                "- ЗАПРЕЩЕНО уходить в ближайшую похожую тему из system prompt только потому что не нашёл точного ответа. Например: юзер про мем → ты не знаешь → НЕ отвечай погодой только потому что в инструкции упоминается погода.\\n"
                "- ЗАПРЕЩЕНО возвращать «random fact» когда юзер задал конкретный вопрос. Лучше честное «не знаю», чем неточный/несвязанный ответ.\\n"
                "- Если вопрос про мем / культурный артефакт / специфическое явление которое ты не знаешь — предложи юзеру дать ссылку / описание / контекст, чтобы ты мог помочь дальше.\\n"
                "- web_search можно вызвать если есть шанс что в интернете найдётся информация (например мемы из рунета часто есть на urbandictionary, knowyourmeme, wikipedia). Но если поиск ничего не дал — снова «не нашёл», не выдумывай.\\n\\n"
'''

# Anchor — рядом с v10 anti-hallucination или v14 profile-aware
anchors = [
    '"АНТИ-ГАЛЛЮЦИНАЦИЯ ФИНАНСОВЫХ ДАННЫХ (v10',
    '"ПАМЯТЬ КОНТЕКСТА (v18',
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
    src = src[:insert_pos] + GENERAL_AH_RULE + src[insert_pos:]
    print(f"✅ General anti-hallucination injected после {anchor[:40]!r}")
    inserted = True
    break

if not inserted:
    print("⚠️  Anchor не найден", file=sys.stderr)
    sys.exit(2)

bot_py.write_text(src, encoding="utf-8")
print(f"✅ bot.py updated. Size: {len(src)} chars.")
PYEOF

[ $? -ne 0 ] && { cp "$BACKUP" "$BOT_PY"; exit 4; }
python3 -m py_compile "$BOT_PY" || { cp "$BACKUP" "$BOT_PY"; exit 5; }
echo "✅ py_compile OK"

git add bot.py
git commit -m "fix(v21): общее анти-галлюцинационное правило в SYSTEM_PROMPT

Юра msg 18041: на 'мем Окак' бот ответил про погоду в Минске.

Root cause: qwen2.5:7b не знает рунет-мем 'Окак'. Вместо честного
'не знаю' малая модель ушла в ближайший знакомый pattern из SYSTEM_PROMPT
(Минск/погода/gismeteo упоминаются там много раз).

Fix: общее правило anti-hallucination — расширение v10 (был только для
финансов) на ВСЕ домены:
- 'не знаю' = нормальный ответ
- запрет подменять тему на знакомую
- запрет 'random fact' вместо точного ответа
- предлагать юзеру дать контекст если не знаком
- web_search опционально, но если ничего не нашёл — снова 'не знаю'

Backup tag: pre-tools-v21. Откат: git reset --hard pre-tools-v21." 2>&1 | tail -5

systemctl --user restart "$SERVICE" 2>&1 | tail -3
sleep 2

echo ""
echo "✅ v21 applied. Tests:"
echo "  «Ты знаешь мем «Окак»?» → 'не знаком с этим мемом, дай ссылку/контекст'"
echo "  «Что такое квантовая запутанность?» → нормальный ответ (это в trained data)"
echo "  «Расскажи про X» где X — fictional → 'не знаком с этим'"
echo ""
echo "Откат: git reset --hard pre-tools-v21"
