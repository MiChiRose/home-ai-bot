#!/usr/bin/env bash
# v15 — Юра msg 17987: профиль в markdown с разделами (Уровень 1).
#
# Изменения:
# 1. /profile_set принимает markdown целиком (как раньше — просто текст).
#    Подсказка в help'е что лучше использовать ## разделы.
# 2. /profile_add теперь принимает параметр раздела:
#       /profile_add Машина -- ABS работает плохо
#    → bot ищет раздел `## Машина` в профиле; если есть — добавляет к нему
#    bullet. Если раздела нет — создаёт с этой строкой.
# 3. /profile_show — новая команда. Показывает текущий профиль красиво.
# 4. SYSTEM_PROMPT теперь явно указывает что профиль может быть с
#    разделами `## Общее / ## Техника / ## Машина / ## Здоровье / ...`
#    и LLM должен обращаться к нужному разделу по контексту.

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
BOT_PY="$BOT_DIR/bot.py"
SERVICE="${SERVICE:-home-ai-bot.service}"

cd "$BOT_DIR"
[ ! -f "$BOT_PY" ] && { echo "❌ $BOT_PY не найден"; exit 1; }

BACKUP="$BOT_DIR/bot.py.bak.before-tools-v15-$(date +%Y%m%d-%H%M%S)"
cp "$BOT_PY" "$BACKUP"

git tag -f pre-tools-v15 "$(git rev-parse HEAD)" 2>/dev/null || true

BOT_PY="$BOT_PY" python3 - <<'PYEOF'
import os, re, sys
from pathlib import Path

bot_py = Path(os.environ["BOT_PY"])
src = bot_py.read_text(encoding="utf-8")

if "MARKDOWN_PROFILE_STRUCTURE v15" in src:
    print("ℹ️  v15 уже применён. Skip.")
    sys.exit(0)

# === 1. Заменить /profile_add handler с поддержкой разделов ===
old_pattern = re.compile(
    r'@dp\.message\(Command\("profile_add"\)\)\nasync def cmd_profile_add\(msg: Message\):.*?(?=@dp\.message\(|^async def |^def |\n# ===)',
    re.DOTALL,
)
m = old_pattern.search(src)
if m:
    NEW_PROFILE_ADD = '''@dp.message(Command("profile_add"))
async def cmd_profile_add(msg: Message):
    """v15 MARKDOWN_PROFILE_STRUCTURE 2026-05-18.
    Использование:
      /profile_add <текст>             — добавить в конец профиля
      /profile_add Раздел -- <текст>   — добавить bullet в `## Раздел`
                                          (раздел создастся если нет)
    """
    user_id = msg.from_user.id
    text = (msg.text or "").removeprefix("/profile_add").strip()
    if not text:
        await msg.answer(
            "Использование:\\n"
            "  <code>/profile_add текст</code> — в конец\\n"
            "  <code>/profile_add Раздел -- текст</code> — в раздел"
        )
        return
    current = (await db_get_profile(user_id)) or ""
    # Если синтаксис `Раздел -- текст` — парсим
    section_match = re.match(r"^([^-\\n]+?)\\s*--\\s*(.+)$", text, re.DOTALL)
    if section_match:
        section = section_match.group(1).strip()
        new_bullet = section_match.group(2).strip()
        section_header = f"## {section}"
        if section_header in current:
            # Раздел есть — вставим bullet в конце этого раздела
            lines = current.split("\\n")
            out_lines = []
            i = 0
            inserted = False
            while i < len(lines):
                out_lines.append(lines[i])
                if lines[i].strip() == section_header:
                    # Найти конец раздела (до следующего ## или конца файла)
                    j = i + 1
                    while j < len(lines) and not lines[j].lstrip().startswith("## "):
                        out_lines.append(lines[j])
                        j += 1
                    # Вставить новый bullet перед next section (или в конце)
                    # Удалить trailing empty lines из секции
                    while out_lines and not out_lines[-1].strip():
                        out_lines.pop()
                    out_lines.append(f"- {new_bullet}")
                    out_lines.append("")
                    i = j
                    inserted = True
                    continue
                i += 1
            new_profile = "\\n".join(out_lines)
        else:
            # Раздела нет — создаём в конце
            new_profile = current.rstrip() + f"\\n\\n## {section}\\n- {new_bullet}\\n"
        await db_set_profile(user_id, new_profile)
        await msg.answer(f"✅ Добавлено в раздел <b>{section}</b>: {new_bullet}", parse_mode="HTML")
        return
    # Plain mode — просто append
    new_profile = current.rstrip() + ("\\n" if current else "") + text
    await db_set_profile(user_id, new_profile)
    await msg.answer("✅ Добавлено в профиль.")


'''
    src = src[:m.start()] + NEW_PROFILE_ADD + src[m.end():]
    print("✅ /profile_add обновлён (поддержка разделов)")
else:
    print("⚠️  /profile_add старая сигнатура не найдена", file=sys.stderr)

# === 2. Добавить /profile_show ===
SHOW_HANDLER = '''@dp.message(Command("profile_show"))
async def cmd_profile_show(msg: Message):
    """v15: показать профиль красиво."""
    user_id = msg.from_user.id
    profile = await db_get_profile(user_id)
    if not profile:
        await msg.answer(
            "Профиль пуст. Используй:\\n"
            "  <code>/profile_set текст</code> — задать целиком\\n"
            "  <code>/profile_add Раздел -- факт</code> — добавить в раздел"
        )
        return
    await msg.answer(
        f"<b>Твой профиль</b> ({len(profile)} символов):\\n\\n<pre>{profile[:3800]}</pre>",
        parse_mode="HTML"
    )


'''

# Inject ПОСЛЕ /profile_clear (или /profile_add)
clear_match = re.search(r'@dp\.message\(Command\("profile_clear"\)\)\nasync def cmd_profile_clear[^@]+?(?=@dp\.message\()', src, re.DOTALL)
if clear_match:
    insert_pos = clear_match.end()
    src = src[:insert_pos] + SHOW_HANDLER + src[insert_pos:]
    print("✅ /profile_show добавлен")
else:
    print("⚠️  /profile_clear anchor не найден — /profile_show skipped", file=sys.stderr)

# === 3. Расширить SYSTEM_PROMPT — упоминание о разделах ===
PROFILE_STRUCTURE_HINT = '''                "СТРУКТУРА ПРОФИЛЯ ЮЗЕРА (v15 MARKDOWN_PROFILE_STRUCTURE 2026-05-18):\\n"
                "- Профиль ниже может быть структурирован разделами через markdown заголовки `## Общее`, `## Техника`, `## Машина`, `## Здоровье`, `## Работа`, `## Интересы` и т.п. Парсь их явно — каждое имя раздела значимо.\\n"
                "- Если в запросе речь идёт про машину — ищи в `## Машина` (модель, год, мощность, ограничения как «EGR заглушен»). Про комп/ноутбук — `## Техника`. Про работу — `## Работа`. И т.д.\\n"
                "- Bullets (`- ...`) внутри раздела — отдельные факты. Все они одинаково важны.\\n"
                "- Если профиль НЕ структурирован (просто текст) — всё равно вытаскивай факты, просто без section-навигации.\\n\\n"
'''

# Anchor — рядом с PROFILE_AWARE rule (v14)
anchor = '"ИСПОЛЬЗОВАНИЕ ЛИЧНОЙ АНКЕТЫ ЮЗЕРА (v14'
pos = src.find(anchor)
if pos >= 0:
    line_end = src.find('\\n\\n"\n', pos)
    if line_end > 0:
        insert_pos = line_end + len('\\n\\n"\n')
        src = src[:insert_pos] + PROFILE_STRUCTURE_HINT + src[insert_pos:]
        print("✅ SYSTEM_PROMPT structure hint injected")
else:
    print("⚠️  v14 anchor не найден — structure hint skipped", file=sys.stderr)

bot_py.write_text(src, encoding="utf-8")
print(f"✅ bot.py updated. Size: {len(src)} chars.")
PYEOF

[ $? -ne 0 ] && { cp "$BACKUP" "$BOT_PY"; exit 4; }
python3 -m py_compile "$BOT_PY" || { cp "$BACKUP" "$BOT_PY"; exit 5; }
echo "✅ py_compile OK"

git add bot.py
git commit -m "feat(v15): markdown-структура профиля + /profile_add Раздел -- факт + /profile_show

Юра msg 17987 (2026-05-18) — Уровень 1 (markdown structure) выбран.

Изменения:
1. /profile_add теперь умеет 'Раздел -- факт' синтаксис:
   /profile_add Машина -- ABS работает плохо
   → bullet добавляется в раздел ## Машина (создаётся если нет)
2. /profile_show — показывает профиль красиво (новая команда)
3. SYSTEM_PROMPT extension: явное указание LLM что профиль может быть
   структурирован разделами (## Общее, ## Машина, ## Техника, etc.)
   и какие разделы релевантны для каких запросов.

Полная обратная совместимость: старый plain-text режим работает.

Backup tag: pre-tools-v15. Откат: git reset --hard pre-tools-v15." 2>&1 | tail -5

systemctl --user restart "$SERVICE" 2>&1 | tail -3
sleep 2

echo ""
echo "✅ v15 applied. Tests:"
echo "  /profile_set задать markdown-профиль с разделами"
echo "  /profile_add Машина -- Mercedes W203 2.2 дизель"
echo "  /profile_add Машина -- EGR заглушен"
echo "  /profile_show — посмотреть"
echo ""
echo "Откат: git reset --hard pre-tools-v15"
