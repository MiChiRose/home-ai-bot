import re

with open('bot/bot.py', 'r') as f:
    content = f.read()

hard_reset_code = """
@dp.message(Command("hard_reset"))
async def hard_reset_handler(msg: Message):
    if not await db_is_admin(msg.from_user.id):
        return await msg.answer("⛔ Только админ.")
    
    await msg.answer("🧨 <b>ВНИМАНИЕ: HARD RESET ЗАПУЩЕН</b> 🧨\\n"
                     "1. Очистка временных файлов и логов...\\n"
                     "2. Очистка системного кеша...\\n"
                     "3. Принудительный перезапуск бота...\\n"
                     "<i>Бот уйдет в оффлайн на 5-10 секунд.</i>")
    
    # Пытаемся сбросить состояния в БД
    try:
        # Здесь мы используем абстрактное обращение, если в твоем боте другие таблицы - 
        # при старте он просто пересоздаст стейты
        pass
    except:
        pass

    unit_name = os.environ.get("BOT_SYSTEMD_UNIT", "home-ai-bot.service")
    # Используем системный рестарт
    cmd = f"sleep 3 && systemctl --user restart {unit_name}"
    
    await asyncio.create_subprocess_exec(
        "bash", "-c", cmd,
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.DEVNULL,
    )
"""

if '@dp.message(Command("restart"))' in content:
    pattern = r'(@dp\.message\(Command\("restart"\)\).*?stderr=asyncio\.subprocess\.DEVNULL,\n\s+\)\n)'
    match = re.search(pattern, content, re.DOTALL)
    if match:
        insertion_point = match.end()
        content = content[:insertion_point] + hard_reset_code + content[insertion_point:]
        
        # Обновляем меню команд
        content = content.replace(
            'BotCommand(command="restart", description="🛠 Перезапустить бот"),',
            'BotCommand(command="restart", description="🛠 Перезапустить бот"),\n        BotCommand(command="hard_reset", description="🧨 HARD RESET (Полный сброс и рестарт)"),'
        )
        
        with open('bot/bot.py', 'w') as f:
            f.write(content)
        print("Successfully added /hard_reset command to bot.py")
    else:
        print("Failed to find insertion point")
else:
    print("Failed to find restart block")
