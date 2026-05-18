#!/usr/bin/env bash
# v20 — Юра msg 18038: добавить bot commands menu (кнопка с тремя полосками
# в Telegram → выпадающий список команд).
#
# Это standard Telegram Bot API feature через bot.set_my_commands().
# С scope можно разделять:
#   - Default (всем юзерам)
#   - Admin (BOT_ADMIN_IDS) — расширенный список

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
BOT_PY="$BOT_DIR/bot.py"
SERVICE="${SERVICE:-home-ai-bot.service}"

cd "$BOT_DIR"
[ ! -f "$BOT_PY" ] && { echo "❌ $BOT_PY не найден"; exit 1; }

python3 -m py_compile "$BOT_PY" || {
    echo "❌ bot.py УЖЕ broken. Сначала восстанови."
    exit 1
}

BACKUP="$BOT_DIR/bot.py.bak.before-tools-v20-$(date +%Y%m%d-%H%M%S)"
cp "$BOT_PY" "$BACKUP"
git tag -f pre-tools-v20 "$(git rev-parse HEAD)" 2>/dev/null || true

BOT_PY="$BOT_PY" python3 - <<'PYEOF'
import os, re, sys
from pathlib import Path

bot_py = Path(os.environ["BOT_PY"])
src = bot_py.read_text(encoding="utf-8")

if "BOT_COMMANDS_MENU v20" in src:
    print("ℹ️  v20 уже применён.")
    sys.exit(0)

# === 1. Inject setup_commands_menu function перед main() ===
SETUP_FN = '''
# v20 BOT_COMMANDS_MENU 2026-05-18 — set_my_commands для default + admin scope
async def setup_commands_menu(bot, admin_ids: list[int]):
    """Регистрирует commands в Telegram menu (кнопка с 3 полосками).

    Default scope — для всех юзеров.
    Admin scope — для каждого admin'а персонально (расширенный список).
    """
    from aiogram.types import BotCommand, BotCommandScopeDefault, BotCommandScopeChat

    # Команды для ВСЕХ юзеров
    default_commands = [
        BotCommand(command="start", description="Начать"),
        BotCommand(command="profile", description="Мой профиль"),
        BotCommand(command="profile_show", description="Показать профиль"),
        BotCommand(command="profile_set", description="Задать профиль"),
        BotCommand(command="profile_add", description="Добавить факт (или /profile_add Раздел -- факт)"),
        BotCommand(command="profile_clear", description="Очистить профиль"),
        BotCommand(command="reset", description="Сбросить историю диалога"),
        BotCommand(command="context_show", description="Сколько контекста занято"),
    ]
    try:
        await bot.set_my_commands(default_commands, scope=BotCommandScopeDefault())
        log.info("bot_commands configured (default scope, %d commands)", len(default_commands))
    except Exception as e:
        log.warning("set_my_commands default failed: %s", e)

    # Расширенные команды ТОЛЬКО для админов
    admin_commands = default_commands + [
        BotCommand(command="health", description="🛠 Состояние бота"),
        BotCommand(command="health_detail", description="🛠 Детальная диагностика"),
        BotCommand(command="stats", description="🛠 Статистика юзеров"),
        BotCommand(command="add", description="🛠 Добавить юзера в whitelist"),
        BotCommand(command="remove", description="🛠 Убрать юзера"),
        BotCommand(command="list", description="🛠 Список whitelist"),
        BotCommand(command="logs", description="🛠 Логи бота"),
        BotCommand(command="restart", description="🛠 Перезапустить бот"),
        BotCommand(command="restart_ollama", description="🛠 Перезапустить Ollama"),
        BotCommand(command="git_status", description="🛠 Git статус"),
        BotCommand(command="git_log", description="🛠 Git история"),
        BotCommand(command="git_pull", description="🛠 Git pull"),
        BotCommand(command="git_checkout", description="🛠 Git checkout"),
        BotCommand(command="confirm_checkout", description="🛠 Подтвердить checkout"),
        BotCommand(command="confirm_update", description="🛠 Подтвердить update"),
        BotCommand(command="cancel_update", description="🛠 Отменить update"),
    ]
    for admin_id in admin_ids:
        try:
            await bot.set_my_commands(admin_commands, scope=BotCommandScopeChat(chat_id=admin_id))
            log.info("bot_commands configured for admin %s (%d commands)", admin_id, len(admin_commands))
        except Exception as e:
            log.warning("set_my_commands admin %s failed: %s", admin_id, e)


'''

anchor = "async def main():"
pos = src.find(anchor)
if pos < 0:
    print("❌ main() не найден", file=sys.stderr)
    sys.exit(2)
src = src[:pos] + SETUP_FN + src[pos:]
print("✅ setup_commands_menu function injected перед main()")

# === 2. Вызвать setup_commands_menu в main() перед dp.start_polling ===
# Найти первый dp.start_polling и вставить вызов перед ним
start_polling_pos = src.find("await dp.start_polling(")
if start_polling_pos < 0:
    print("⚠️  start_polling не найден — manual injection нужен", file=sys.stderr)
else:
    # Найти отступ строки
    line_start = src.rfind("\n", 0, start_polling_pos) + 1
    indent = src[line_start:start_polling_pos]  # whitespace before await
    # Inject before
    call_block = f'''{indent}# v20 BOT_COMMANDS_MENU: настроить меню перед стартом polling
{indent}try:
{indent}    await setup_commands_menu(bot, list(ADMIN_IDS) if isinstance(ADMIN_IDS, (set, list)) else [])
{indent}except Exception as e:
{indent}    log.warning("commands menu setup failed: %s", e)
'''
    src = src[:start_polling_pos] + call_block + indent + src[start_polling_pos:]
    print("✅ setup_commands_menu вызван перед start_polling")

# === Marker ===
if "# v20 BOT_COMMANDS_MENU" not in src[:300]:
    src = "# v20 BOT_COMMANDS_MENU 2026-05-18 — Telegram commands menu с default+admin scope\n" + src

bot_py.write_text(src, encoding="utf-8")
print(f"✅ bot.py updated. Size: {len(src)} chars.")
PYEOF

[ $? -ne 0 ] && { cp "$BACKUP" "$BOT_PY"; exit 4; }
python3 -m py_compile "$BOT_PY" || {
    echo "❌ py_compile failed. Restoring backup."
    cp "$BACKUP" "$BOT_PY"
    exit 5
}
echo "✅ py_compile OK"

git add bot.py
git commit -m "feat(v20): Telegram commands menu (кнопка с 3 полосками)

Юра msg 18038: добавить bot menu с командами.

Implementation:
- setup_commands_menu(bot, admin_ids) function injected перед main()
- BotCommandScopeDefault: /start, /profile*, /profile_show, /profile_set,
  /profile_add, /profile_clear, /reset, /context_show (8 commands for all)
- BotCommandScopeChat per admin_id: + /health, /health_detail, /stats,
  /add, /remove, /list, /logs, /restart, /restart_ollama, /git_*,
  /confirm_* (16 admin-only commands)
- Вызов перед dp.start_polling в main()

Backup tag: pre-tools-v20. Откат: git reset --hard pre-tools-v20." 2>&1 | tail -5

systemctl --user restart "$SERVICE" 2>&1 | tail -3
sleep 3

echo ""
echo "✅ v20 applied. Tests:"
echo "  Открой Telegram → бот @home-ai-bot → должна появиться кнопка с 3 полосками слева от input"
echo "  Тапни → список команд (8 для всех + админ должен видеть 16+)"
echo "  Логи: journalctl --user -u home-ai-bot.service | grep 'bot_commands configured'"
echo ""
echo "Откат: git reset --hard pre-tools-v20"
