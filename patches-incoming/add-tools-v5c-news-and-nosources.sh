#!/usr/bin/env bash
# add-tools-v5c-news-and-nosources.sh
# Юра msg 17850+17863 (2026-05-18) — добавляем:
#   1. NEWS-блок: приоритет belta.by + onliner.by для новостей РБ
#   2. NO-SOURCES rule: не упоминать URL/название источника в финальном ответе
#   3. Verify try_factual_intent_routing wire'ится (v5b проверка)
#
# Anchor: между SMALL-TALK блоком и ФОРМАТ ОТВЕТА (строки ~49-52 в snippet).

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
BOT_PY="$BOT_DIR/bot.py"
SERVICE="${SERVICE:-home-ai-bot.service}"

cd "$BOT_DIR"
[ ! -f "$BOT_PY" ] && { echo "❌ $BOT_PY не найден"; exit 1; }

echo "==> BOT_DIR: $BOT_DIR"
echo "==> bot.py: $(wc -l < "$BOT_PY") строк"

BACKUP="$BOT_DIR/bot.py.bak.before-tools-v5c-$(date +%Y%m%d-%H%M%S)"
cp "$BOT_PY" "$BACKUP"
echo "✅ backup: $BACKUP"

git tag -f pre-tools-v5c "$(git rev-parse HEAD)" 2>/dev/null || true

BOT_PY="$BOT_PY" python3 - <<'PYEOF'
import os
import re
import sys
from pathlib import Path

bot_py = Path(os.environ["BOT_PY"])
src = bot_py.read_text(encoding="utf-8")

# ========================================================================
# 1. NEWS-блок + NO-SOURCES rule инжект ПОСЛЕ SMALL-TALK блока
# ========================================================================
NEWS_NOSOURCES_BLOCK = '''                "НОВОСТИ И ФАКТУАЛЬНЫЕ ЗАПРОСЫ ПО РБ (added v5c 2026-05-18):\\n"
                "- Новости Беларуси / события дня / происшествия — приоритет belta.by + onliner.by. Fallback: sb.by, kp.by, tut.by (architectural), tribuna.com (спорт), sportarena.by.\\n"
                "- Финансовые / курсы / экономика РБ — приоритет nbrb.by (Нацбанк, котировки официальные) + myfin.by (обменники). Fallback belmarket.by.\\n"
                "- Погода РБ — приоритет gismeteo.by + pogoda.by. НЕ давай tiktok/youtube ссылки на погоду.\\n"
                "- web_search query формируй с явными site:belta.by site:onliner.by операторами или конкретными доменами в тексте запроса.\\n\\n"
                "НЕ УПОМИНАЙ ИСТОЧНИКИ В ФИНАЛЬНОМ ОТВЕТЕ (added v5c 2026-05-18):\\n"
                "- ЗАПРЕЩЕНО писать «По данным belta.by...», «Согласно onliner.by...», «Источник: nbrb.by», «Ссылка: ...», давать URL списком, перечислять домены.\\n"
                "- Юзер хочет ФАКТ, не библиографию. Просто: «Курс доллара на сегодня — 2.7535 BYN.» Без «по данным НБРБ».\\n"
                "- Если факт не подтверждён или конфликтные данные — скажи «не нашёл актуальных данных», БЕЗ списка сайтов для самостоятельной проверки.\\n\\n"
'''

if "НОВОСТИ И ФАКТУАЛЬНЫЕ ЗАПРОСЫ ПО РБ" in src:
    print("ℹ️  v5c NEWS+NOSOURCES уже инжектирован. Skip.")
else:
    # Anchor — конец SMALL-TALK блока (последняя строка перед ФОРМАТ ОТВЕТА).
    # Из snippet'а Юры: SMALL-TALK заканчивается на «Не на каждое сообщение.\\n\\n»
    smalltalk_end = src.find('"- web_search вызывай ТОЛЬКО когда юзер реально просит факт')
    if smalltalk_end < 0:
        print("❌ SMALL-TALK anchor не найден.", file=sys.stderr)
        sys.exit(2)

    # Найти конец этой строки (с \\n\\n")
    line_end = src.find('\\n\\n"\n', smalltalk_end)
    if line_end < 0:
        print("❌ Конец SMALL-TALK строки не найден.", file=sys.stderr)
        sys.exit(3)

    insert_pos = line_end + len('\\n\\n"\n')
    src = src[:insert_pos] + NEWS_NOSOURCES_BLOCK + src[insert_pos:]
    print(f"✅ Injected NEWS + NO-SOURCES после SMALL-TALK (pos={insert_pos})")

# ========================================================================
# 2. Verify try_factual_intent_routing wire'ится (v5b sanity)
# ========================================================================
if "factual intent routing ДО LLM" in src:
    print("✅ v5b wire (factual_intent_routing) присутствует в chat_handler.")
else:
    print("⚠️  v5b wire НЕ найден — v5b не применился. Применяй сначала v5b!")

# ========================================================================
# 3. Verify get_nbrb_rate + get_gismeteo_weather функции есть
# ========================================================================
funcs_present = []
for fn in ("get_nbrb_rate", "get_gismeteo_weather", "try_factual_intent_routing"):
    if f"def {fn}(" in src or f"async def {fn}(" in src:
        funcs_present.append(fn)
print(f"✅ Функции v5 присутствуют: {funcs_present}")
if len(funcs_present) < 3:
    missing = {"get_nbrb_rate", "get_gismeteo_weather", "try_factual_intent_routing"} - set(funcs_present)
    print(f"⚠️  Отсутствуют: {missing} — применяй сначала v5!")

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
git commit -m "feat(v5c): NEWS-блок + NO-SOURCES правила в SYSTEM_PROMPT

Юра msg 17850+17863 (2026-05-18) — финальная доводка после v5+v5b.

Changes:
1. NEWS-блок: приоритет belta.by + onliner.by для новостей РБ.
   Финансы → nbrb.by + myfin.by. Погода → gismeteo.by + pogoda.by.
   web_search query с site: операторами.
2. NO-SOURCES rule: запрет 'По данным X', 'Источник: Y', URL'ы в финальном
   ответе. Юзер хочет факт, не библиографию.

Backup tag: pre-tools-v5c. Откат: git reset --hard pre-tools-v5c." 2>&1 | tail -5

echo ""
echo "==> restart $SERVICE"
systemctl --user restart "$SERVICE" 2>&1 | tail -3
sleep 2
systemctl --user status "$SERVICE" --no-pager 2>&1 | head -8

echo ""
echo "✅ v5c applied. Tests:"
echo "  «новости беларуси» → должен вернуть факты без 'по данным belta.by'"
echo "  «курс доллара» → '2.7535 BYN' без 'источник НБРБ'"
echo "  «погода в Минске» → погода без 'tiktok' / 'youtube' ссылок"
echo ""
echo "Откат:"
echo "  git reset --hard pre-tools-v5c"
echo "  cp '$BACKUP' '$BOT_PY'"
echo "  systemctl --user restart $SERVICE"
