import re

with open('bot/bot.py', 'r') as f:
    content = f.read()

# 1. Добавляем /last_queries - просмотр последних запросов
last_queries_code = """
@dp.message(Command("last_queries"))
async def last_queries_handler(msg: Message):
    if not await db_is_admin(msg.from_user.id):
        return await msg.answer("⛔ Только админ.")
    
    db = await _get_db()
    # Берем последние 10 сообщений от пользователей (не от бота)
    async with db.execute(
        "SELECT user_id, content, timestamp FROM messages WHERE role='user' ORDER BY timestamp DESC LIMIT 10"
    ) as c:
        rows = await c.fetchall()
    
    if not rows:
        return await msg.answer("История запросов пуста.")
    
    text = "🔍 <b>Последние 10 запросов юзеров:</b>\\n\\n"
    for uid, content, ts in rows:
        # Обрезаем длинные сообщения
        short_content = (content[:50] + '...') if len(content) > 50 else content
        text += f"👤 <code>{uid}</code> | {ts}\\n📝 {short_content}\\n\\n"
    
    await msg.answer(text)

@dp.message(Command("analytics"))
async def analytics_handler(msg: Message):
    if not await db_is_admin(msg.from_user.id):
        return await msg.answer("⛔ Только админ.")
    
    db = await _get_db()
    # Считаем общую статистику
    async with db.execute("SELECT COUNT(DISTINCT user_id) FROM messages") as c:
        users_count = (await c.fetchone())[0]
    async with db.execute("SELECT COUNT(*) FROM messages") as c:
        total_msgs = (await c.fetchone())[0]
    async with db.execute("SELECT COUNT(*) FROM messages WHERE role='user' AND timestamp > datetime('now', '-24 hours')") as c:
        msgs_24h = (await c.fetchone())[0]
    
    text = (
        "📈 <b>Глобальная аналитика:</b>\\n\\n"
        f"👥 Всего пользователей в базе: <b>{users_count}</b>\\n"
        f"✉️ Всего сообщений: <b>{total_msgs}</b>\\n"
        f"🕒 Запросов за 24 часа: <b>{msgs_24h}</b>\\n\\n"
        "<i>База данных: SQLite (.db)</i>"
    )
    await msg.answer(text)
"""

# Вставляем новые хендлеры перед setup_commands_menu
if 'async def setup_commands_menu' in content:
    content = content.replace('async def setup_commands_menu', last_queries_code + '\nasync def setup_commands_menu')
    
    # Обновляем меню команд
    content = content.replace(
        'BotCommand(command="stats", description="🛠 Статистика юзеров"),',
        'BotCommand(command="stats", description="🛠 Статистика юзеров"),\n        BotCommand(command="last_queries", description="🛠 Последние запросы юзеров"),\n        BotCommand(command="analytics", description="📈 Глобальная аналитика"),'
    )
    
    with open('bot/bot.py', 'w') as f:
        f.write(content)
    print("Successfully added /last_queries and /analytics to bot.py")
else:
    print("Failed to find insertion point in bot.py")
