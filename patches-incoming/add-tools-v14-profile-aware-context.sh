#!/usr/bin/env bash
# v14 — Юра msg 17972: бот должен использовать user_profile как контекст для
# притяжательных запросов («моя машина», «мой комп», «моя работа», и т.д.).
#
# Сейчас profile вкладывается в SYSTEM_PROMPT, но LLM не всегда вытаскивает
# оттуда конкретику для web_search query. Например «когда менять масло в моей
# машине» → LLM должен взять «Mercedes 203, 2.2 дизель» из profile + 
# сформулировать поисковый запрос с этими данными.
#
# Fix: явное правило в SYSTEM_PROMPT — ВСЕГДА сначала проверять профиль на
# притяжательные местоимения и личные ссылки, ПОТОМ строить ответ/поиск.

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
BOT_PY="$BOT_DIR/bot.py"
SERVICE="${SERVICE:-home-ai-bot.service}"

cd "$BOT_DIR"
[ ! -f "$BOT_PY" ] && { echo "❌ $BOT_PY не найден"; exit 1; }

BACKUP="$BOT_DIR/bot.py.bak.before-tools-v14-$(date +%Y%m%d-%H%M%S)"
cp "$BOT_PY" "$BACKUP"

git tag -f pre-tools-v14 "$(git rev-parse HEAD)" 2>/dev/null || true

BOT_PY="$BOT_PY" python3 - <<'PYEOF'
import os, sys
from pathlib import Path

bot_py = Path(os.environ["BOT_PY"])
src = bot_py.read_text(encoding="utf-8")

if "PROFILE_AWARE_CONTEXT v14" in src:
    print("ℹ️  v14 уже применён. Skip.")
    sys.exit(0)

PROFILE_RULE = '''                "ИСПОЛЬЗОВАНИЕ ЛИЧНОЙ АНКЕТЫ ЮЗЕРА (v14 PROFILE_AWARE_CONTEXT 2026-05-18, обязательно):\\n"
                "- В user_profile (раздел «ПЕРСОНАЛЬНЫЙ ПРОФИЛЬ ЮЗЕРА» ниже) хранятся факты о юзере: техника, машина, работа, инструменты, интересы, предпочтения, географическая локация и т.п.\\n"
                "- Если в запросе встречается ПРИТЯЖАТЕЛЬНОЕ МЕСТОИМЕНИЕ («мой/моя/моё/мои», «у меня», «у нас», «нашего», «моему») ИЛИ ссылка на личный предмет/атрибут БЕЗ уточнения («машина», «комп», «ноутбук», «работа», «дача», «телефон», «инструмент», «коллекция», «велик» и подобное) — ПЕРВЫМ делом ищи соответствующее упоминание в user_profile.\\n"
                "- Если нашёл — ОБЯЗАТЕЛЬНО подставь конкретику в свой ответ И в формирование web_search query. Пример: запрос «когда менять масло в моей машине» при наличии в профиле «Mercedes 203, 2000 г., 2.2 дизель» → query типа «масло замена Mercedes W203 2.2 дизель регламент».\\n"
                "- Не переспрашивай «а какая у вас машина», «какая модель ноутбука» если ответ уже есть в анкете. Это раздражает юзера.\\n"
                "- Если в анкете нет нужной детали — тогда можно вежливо уточнить.\\n"
                "- Профиль может содержать ОТРИЦАТЕЛЬНЫЕ оговорки («EGR заглушен — из диагнозов исключать»). Учитывай и эти ограничения тоже.\\n\\n"
'''

# Anchor — после security rule (v11) или anti-hallucination (v10), или small-talk (v5b)
anchors = [
    '"ГЛОБАЛЬНОЕ ПРАВИЛО БЕЗОПАСНОСТИ (v11',
    '"АНТИ-ГАЛЛЮЦИНАЦИЯ ФИНАНСОВЫХ ДАННЫХ (v10',
    '"- web_search вызывай ТОЛЬКО когда юзер реально просит факт',
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
    src = src[:insert_pos] + PROFILE_RULE + src[insert_pos:]
    print(f"✅ Profile-aware rule injected после {anchor[:40]!r}")
    inserted = True
    break

if not inserted:
    print("❌ Anchor не найден", file=sys.stderr)
    sys.exit(2)

bot_py.write_text(src, encoding="utf-8")
print(f"✅ bot.py updated. Size: {len(src)} chars.")
PYEOF

[ $? -ne 0 ] && { cp "$BACKUP" "$BOT_PY"; exit 4; }
python3 -m py_compile "$BOT_PY" || { cp "$BACKUP" "$BOT_PY"; exit 5; }
echo "✅ py_compile OK"

git add bot.py
git commit -m "feat(v14): profile-aware context для притяжательных запросов

Юра msg 17972 (2026-05-18): бот не использует данные анкеты как контекст
для запросов с 'моя машина', 'мой комп' и т.д.

Fix: явное правило в SYSTEM_PROMPT.
- При запросе с притяжательным местоимением (мой/моя/моё/мои/у меня) или
  ссылкой на личный предмет — ПЕРВЫМ делом ищи в user_profile.
- Найденную конкретику ОБЯЗАТЕЛЬНО подставляй в ответ и в web_search query.
- Не переспрашивай если ответ уже в анкете.
- Учитывай отрицательные оговорки (например 'EGR заглушен').

Сам profile уже передаётся в SYSTEM_PROMPT через _post_init блок (bug 4 fix
2026-05-17) — это правило усиливает его использование.

Backup tag: pre-tools-v14. Откат: git reset --hard pre-tools-v14." 2>&1 | tail -5

systemctl --user restart "$SERVICE" 2>&1 | tail -3
sleep 2

echo ""
echo "✅ v14 applied. Tests:"
echo "  «когда менять масло в моей машине?» → бот учитывает Mercedes 203 + 2.2 дизель"
echo "  «как почистить мой ноутбук?» → учитывает MBP 14 M1 Pro"
echo "  «нужен ли мне новый комп?» → учитывает существующие маки"
echo "  «у нас есть гараж?» → если в анкете нет — вежливо уточнит"
echo ""
echo "Откат: git reset --hard pre-tools-v14"
