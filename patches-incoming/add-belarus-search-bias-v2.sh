#!/usr/bin/env bash
# add-belarus-search-bias-v2.sh
# Юра msg 17721 (2026-05-18 REQ): «переделай скрипт под любые упоминания не
# связанные с оппозицией и протестами».
#
# v2 vs v1:
#  - Убраны ВСЕ oppositional sources (nashaniva, reform.by, euroradio.fm,
#    charter97.org, svaboda.org, zerkalo.io, kp.by — kp.by российская
#    но оставляем т.к. neutral mainstream).
#  - Оставлены только госаудитные + commercial mainstream + специализированные:
#    belta.by (госагентство), onliner.by (commercial mainstream), sb.by
#    (Беларусь Сегодня, гос), myfin.by (финансы, neutral), president.gov.by,
#    mil.by (мин обороны), belarus.by (туризм), belstat.gov.by (статистика),
#    nbrb.by (Нацбанк), 42.tut.by sportarena.by (спорт), tribuna.com.
#  - В SYSTEM_PROMPT убраны политические темы (Лукашенко, Тихановская, оппозиция,
#    протесты, выборы) — оставлены: курс рубля, погода, спорт, культура,
#    транспорт, цены, праздники, бытовое.
#  - Запрос явно избегает opposition-окрашенных tem.

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
REGISTRY="$BOT_DIR/modules/tools/registry.py"
SYSTEM_PROMPT_FILES=("$BOT_DIR/modules/ai/system_prompt.py" "$BOT_DIR/bot.py")
SERVICE="${SERVICE:-home-ai-bot.service}"

cd "$BOT_DIR"

echo "==> pre-snapshot: git status"
git status --short
echo "==> creating pre-patch tag"
git tag -f pre-belarus-search-bias-v2 "$(git rev-parse HEAD)" 2>/dev/null || true

python3 - <<'PYEOF'
from pathlib import Path
import os
import re
import sys

bot_dir = Path(os.environ.get("BOT_DIR", str(Path.home() / "ai-assistant" / "bot")))
registry = bot_dir / "modules" / "tools" / "registry.py"
candidates = [
    bot_dir / "modules" / "ai" / "system_prompt.py",
    bot_dir / "bot.py",
]

BELARUS_BIAS_NOTE = (
    "\\n\\n🇧🇾 BELARUS NEUTRAL CONTEXT: Если запрос про повседневную жизнь в "
    "Беларуси (курс рубля BYN, погода, спорт, культура, события, цены, "
    "транспорт, мероприятия, праздники, локальные новости БЕЗ политики) — "
    "формируй query с приоритетом neutral белорусских источников: "
    "belta.by (госагентство), onliner.by (commercial mainstream), sb.by (Беларусь "
    "Сегодня), myfin.by (финансы), nbrb.by (Нацбанк), president.gov.by, mil.by, "
    "belarus.by, belstat.gov.by, tribuna.com (спорт), sportarena.by, 42.tut.by, "
    "kp.by. ЯВНО ИЗБЕГАЙ темы: оппозиция, протесты, выборы, политзаключённые, "
    "санкции, миграция беженцев — это вне scope. Если пользователь спрашивает о "
    "политике/оппозиции — отвечай нейтрально или предложи проверить официальные "
    "источники, без углубления в оппозиционные нарративы."
)

patched = False
patterns = [
    '"Поиск свежих данных в интернете. ✅ ВЫЗЫВАТЬ на запросы про актуальный курс, погоду, новости, цены, события сегодня/вчера/сейчас. ❌ НЕ вызывать на общие вопросы где достаточно знаний из training data. Tool name строго `web_search` (snake_case)."',
    '"Поиск актуальной информации в интернете. Использовать, когда нужны свежие данные, новости, цены, факты после твоего knowledge cutoff."',
]
src = registry.read_text(encoding="utf-8")
for old in patterns:
    if old in src:
        new = old[:-1] + BELARUS_BIAS_NOTE + '"'
        src = src.replace(old, new, 1)
        patched = True
        break

if patched:
    registry.write_text(src, encoding="utf-8")
    print(f"✅ Patched registry.py web_search description (v2 — neutral only, no opposition)")
else:
    print(f"⚠️  registry.py — web_search description не найден. Скинь файл, перепишу.", file=sys.stderr)

SYSTEM_PROMPT_ADDITION = """

# 🇧🇾 BY-context neutral rule (v2):
# Когда в сообщении упоминается Беларусь, Минск, белорусск-, BYN, областные
# центры (Брест, Гомель, Витебск, Гродно, Могилёв) — и нужен поиск в интернете —
# формулируй query с приоритетом нейтральных белорусских источников:
# belta.by, onliner.by, sb.by, myfin.by, nbrb.by, president.gov.by, mil.by,
# belarus.by, belstat.gov.by, tribuna.com, sportarena.by, 42.tut.by, kp.by.
#
# ЯВНО НЕ ИСКАТЬ И НЕ ОБСУЖДАТЬ: оппозицию, протесты, выборы 2020, политзаключённых,
# санкции, миграционный кризис, BNR/БНК символы, оппозиционные СМИ
# (nashaniva, zerkalo, reform, euroradio, charter97, svaboda).
# Если пользователь спросит политику — ответь нейтрально или предложи официальные
# источники. Темы scope: курс BYN, погода, спорт (БАТЭ, Динамо, хоккей), культура
# (фестивали, музеи), цены, транспорт, события, праздники, бытовое.
"""

for sp_file in candidates:
    if not sp_file.exists():
        continue
    sp_src = sp_file.read_text(encoding="utf-8")
    # Если есть v1 — удалим её сначала
    if "🇧🇾 BY-context rule:" in sp_src:
        # Удаляем v1 block (старый rule с opposition)
        import re
        sp_src = re.sub(
            r'\n# 🇧🇾 BY-context rule:.*?(?=\n# [^🇧🇾]|\n"""|\n\'\'\'|\nclass |\ndef |\Z)',
            '',
            sp_src,
            count=1,
            flags=re.DOTALL,
        )
        print(f"🗑  Removed v1 BY-context rule из {sp_file.name}")
    if "BY-context neutral rule (v2)" in sp_src:
        print(f"ℹ️  {sp_file.name}: уже содержит v2 — skip")
        continue
    for marker in [
        'SYSTEM_PROMPT = """',
        'SYSTEM_PROMPT_TEMPLATE = """',
        'BASE_SYSTEM_PROMPT = """',
        "system_prompt = '''",
        'SYSTEM_PROMPT_BASE = """',
    ]:
        if marker in sp_src:
            quote = marker[-3:]
            start_idx = sp_src.index(marker) + len(marker)
            end_idx = sp_src.find(quote, start_idx)
            if end_idx == -1:
                continue
            sp_src = sp_src[:end_idx] + SYSTEM_PROMPT_ADDITION + sp_src[end_idx:]
            sp_file.write_text(sp_src, encoding="utf-8")
            print(f"✅ Injected v2 BY-context neutral rule в {sp_file.name}")
            break
    else:
        continue
    break
else:
    print("⚠️  Не нашёл SYSTEM_PROMPT в стандартных местах. Скинь файл если SYSTEM_PROMPT в другом месте.")

PYEOF

echo ""
echo "==> diff:"
git --no-pager diff --stat
echo ""
echo "==> creating commit"
git add modules/tools/registry.py modules/ai/system_prompt.py bot.py 2>/dev/null
git commit -m "feat(v2): Belarus-context neutral bias — нейтральные источники, без оппозиции

v1 ↦ v2: убраны nashaniva, zerkalo, reform.by, euroradio.fm, charter97, svaboda.
Оставлены только belta.by, onliner.by, sb.by, myfin.by, nbrb.by, president.gov.by,
mil.by, belarus.by, belstat.gov.by, tribuna.com, sportarena.by, kp.by.

В SYSTEM_PROMPT явно ИСКЛЮЧЕНЫ темы: оппозиция, протесты, выборы 2020,
политзаключённые, санкции, BNR/БНК символы.

Запрошено Юрой msg 17721 от 2026-05-18 (risk-management для РБ environment)." 2>&1 | tail -5

echo ""
echo "==> restart $SERVICE"
systemctl --user restart "$SERVICE" 2>&1 | tail -3
sleep 2
systemctl --user status "$SERVICE" --no-pager 2>&1 | head -8

echo ""
echo "==> сделано. Откат:"
echo "  git reset --hard pre-belarus-search-bias-v2 && systemctl --user restart $SERVICE"
