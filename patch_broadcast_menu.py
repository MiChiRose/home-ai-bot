import re

with open('bot/bot.py', 'r') as f:
    content = f.read()

# Добавляем команду /broadcast в меню админа
if 'BotCommand(command="logs", description="🛠 Логи бота"),' in content:
    content = content.replace(
        'BotCommand(command="logs", description="🛠 Логи бота"),',
        'BotCommand(command="logs", description="🛠 Логи бота"),\n        BotCommand(command="broadcast", description="📢 Рассылка всем пользователям"),'
    )
    with open('bot/bot.py', 'w') as f:
        f.write(content)
    print("Successfully added /broadcast to command menu")
else:
    print("Failed to find 'logs' command in menu")
