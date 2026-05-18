#!/usr/bin/env bash
# add-belarus-search-bias-v3-autodetect.sh
# Юра msg 17727 + 17729: v1/v2 не нашёл registry.py по угаданному пути
# (modules/tools/registry.py). v3 — auto-detect path: ищет registry.py через
# find, выбирает первый match не-в __pycache__, патчит его.
# Если registry.py не найден — печатает structure (для дебага) и выходит.
#
# Также auto-detect system_prompt в bot.py / modules/**/*.py.

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
SERVICE="${SERVICE:-home-ai-bot.service}"

cd "$BOT_DIR"

echo "==> BOT_DIR: $BOT_DIR"
echo "==> ищу registry.py..."
REGISTRY="$(find . -name 'registry.py' -not -path '*/__pycache__/*' -not -path '*/venv/*' -not -path '*/.git/*' 2>/dev/null | head -1)"

if [ -z "$REGISTRY" ]; then
    echo ""
    echo "❌ registry.py не найден в $BOT_DIR"
    echo ""
    echo "==> структура верхнего уровня:"
    ls -la
    echo ""
    echo "==> модули:"
    find . -maxdepth 3 -name '*.py' -not -path '*/__pycache__/*' -not -path '*/venv/*' 2>/dev/null | head -40
    exit 1
fi

REGISTRY_ABS="$(realpath "$REGISTRY")"
echo "✅ нашёл registry.py: $REGISTRY_ABS"

echo "==> ищу SYSTEM_PROMPT..."
SYSTEM_PROMPT_FILE="$(grep -rln 'SYSTEM_PROMPT\s*=\s*"""\|SYSTEM_PROMPT\s*=\s*'"'"''"'"''"'"'\|BASE_SYSTEM_PROMPT\s*=' . --include='*.py' 2>/dev/null | grep -v __pycache__ | head -1)"

if [ -z "$SYSTEM_PROMPT_FILE" ]; then
    echo "⚠️  SYSTEM_PROMPT не найден в стандартной форме. Пропускаю system prompt patch."
    SYSTEM_PROMPT_FILE=""
else
    echo "✅ нашёл SYSTEM_PROMPT в: $SYSTEM_PROMPT_FILE"
fi

echo ""
echo "==> pre-snapshot: git status"
git status --short
echo "==> creating pre-patch tag"
git tag -f pre-belarus-search-bias-v3 "$(git rev-parse HEAD)" 2>/dev/null || true

REGISTRY_PATH="$REGISTRY" SYSTEM_PROMPT_PATH="${SYSTEM_PROMPT_FILE:-}" python3 - <<'PYEOF'
from pathlib import Path
import os
import re
import sys

registry = Path(os.environ["REGISTRY_PATH"])
sp_path = os.environ.get("SYSTEM_PROMPT_PATH", "")

BELARUS_BIAS_NOTE = (
    "\\n\\n🇧🇾 BELARUS NEUTRAL CONTEXT: Если запрос про повседневную жизнь в "
    "Беларуси (курс рубля BYN, погода, спорт, культура, события, цены, "
    "транспорт, мероприятия, праздники, локальные новости БЕЗ политики) — "
    "формируй query с приоритетом neutral белорусских источников: "
    "belta.by (госагентство), onliner.by (commercial mainstream), sb.by, "
    "myfin.by, nbrb.by, president.gov.by, mil.by, belarus.by, belstat.gov.by, "
    "tribuna.com (спорт), sportarena.by, 42.tut.by, kp.by. ЯВНО ИЗБЕГАЙ темы: "
    "оппозиция, протесты, выборы, политзаключённые, санкции, миграция, BNR/БНК "
    "символы — это вне scope. Если пользователь спрашивает о политике/оппозиции — "
    "отвечай нейтрально или предложи официальные источники, без углубления в "
    "оппозиционные нарративы."
)

src = registry.read_text(encoding="utf-8")
patched = False

# Try multiple description patterns
patterns_old = [
    '"Поиск свежих данных в интернете. ✅ ВЫЗЫВАТЬ на запросы про актуальный курс, погоду, новости, цены, события сегодня/вчера/сейчас. ❌ НЕ вызывать на общие вопросы где достаточно знаний из training data. Tool name строго `web_search` (snake_case)."',
    '"Поиск актуальной информации в интернете. Использовать, когда нужны свежие данные, новости, цены, факты после твоего knowledge cutoff."',
]
for old in patterns_old:
    if old in src:
        new = old[:-1] + BELARUS_BIAS_NOTE + '"'
        src = src.replace(old, new, 1)
        patched = True
        print(f"✅ Replaced description (matched pattern, +Belarus neutral bias)")
        break

if not patched:
    # Fallback — regex поиск любого web_search description с "Поиск"
    pattern = re.compile(
        r'("description"\s*:\s*"Поиск[^"]+?")',
        re.DOTALL,
    )
    m = pattern.search(src)
    if m:
        old = m.group(1)
        new = old[:-1] + BELARUS_BIAS_NOTE + '"'
        src = src.replace(old, new, 1)
        patched = True
        print(f"✅ Replaced description via regex (matched: {old[:60]}...)")
    else:
        print(f"⚠️  web_search description с 'Поиск' не нашёл — patch применён только к system_prompt")

if patched:
    registry.write_text(src, encoding="utf-8")
    print(f"   → wrote {registry}")

if sp_path:
    sp_file = Path(sp_path)
    sp_src = sp_file.read_text(encoding="utf-8")
    if "🇧🇾 BY-context neutral rule (v3)" in sp_src or "BY-context neutral rule" in sp_src:
        print(f"ℹ️  {sp_file.name}: уже содержит BY-context neutral rule — skip")
    else:
        # Remove v1 if present
        sp_src = re.sub(
            r'\n# 🇧🇾 BY-context rule:.*?(?=\n# [^🇧🇾]|\n"""|\n\'\'\'|\nclass |\ndef |\Z)',
            '',
            sp_src,
            count=1,
            flags=re.DOTALL,
        )
        # Inject v3 rule
        SYSTEM_PROMPT_ADDITION = """

# 🇧🇾 BY-context neutral rule (v3):
# Когда упоминаются Беларусь, Минск, белорусск-, BYN, областные центры
# (Брест, Гомель, Витебск, Гродно, Могилёв) — формулируй query с приоритетом
# нейтральных белорусских источников: belta.by, onliner.by, sb.by, myfin.by,
# nbrb.by, president.gov.by, mil.by, belarus.by, belstat.gov.by, tribuna.com,
# sportarena.by, 42.tut.by, kp.by.
#
# ЯВНО НЕ ИСКАТЬ И НЕ ОБСУЖДАТЬ: оппозиция, протесты, выборы 2020,
# политзаключённые, санкции, миграционный кризис, BNR/БНК символы,
# оппозиционные СМИ (nashaniva, zerkalo, reform, euroradio, charter97, svaboda).
# Темы scope: курс BYN, погода, спорт (БАТЭ, Динамо, хоккей), культура,
# цены, транспорт, события, праздники, бытовое.
"""
        injected = False
        for marker in [
            'SYSTEM_PROMPT = """', 'SYSTEM_PROMPT_TEMPLATE = """',
            'BASE_SYSTEM_PROMPT = """', "system_prompt = '''",
            'SYSTEM_PROMPT_BASE = """', "SYSTEM_PROMPT = '''",
        ]:
            if marker in sp_src:
                quote = marker[-3:]
                start_idx = sp_src.index(marker) + len(marker)
                end_idx = sp_src.find(quote, start_idx)
                if end_idx == -1:
                    continue
                sp_src = sp_src[:end_idx] + SYSTEM_PROMPT_ADDITION + sp_src[end_idx:]
                sp_file.write_text(sp_src, encoding="utf-8")
                print(f"✅ Injected v3 BY-context neutral rule в {sp_file.name} via {marker.strip()}")
                injected = True
                break
        if not injected:
            print(f"⚠️  Marker SYSTEM_PROMPT не найден в {sp_file.name} — patch только registry")
PYEOF

echo ""
echo "==> diff:"
git --no-pager diff --stat
echo ""
echo "==> commit"
git add -A 2>/dev/null
git commit -m "feat(v3): Belarus neutral bias — auto-detect paths

v2 → v3: вместо угаданного пути registry.py — auto-detect через find.
Источники только нейтральные (belta.by, onliner.by, sb.by, myfin.by, nbrb.by,
mil.by, belarus.by, belstat.gov.by, tribuna.com, sportarena.by, 42.tut.by, kp.by).
ЯВНО ИСКЛЮЧЕНЫ: оппозиция, протесты, выборы, политзаключённые, оппозиционные СМИ.

Запрошено Юрой msg 17721 + 17727 (path mismatch fix) от 2026-05-18." 2>&1 | tail -5

echo ""
echo "==> restart $SERVICE"
systemctl --user restart "$SERVICE" 2>&1 | tail -3
sleep 2
systemctl --user status "$SERVICE" --no-pager 2>&1 | head -8

echo ""
echo "==> done. Откат:"
echo "  git reset --hard pre-belarus-search-bias-v3 && systemctl --user restart $SERVICE"
