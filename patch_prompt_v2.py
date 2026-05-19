import re

with open('bot/bot.py', 'r') as f:
    content = f.read()

# Паттерн для поиска текущего блока system prompt (уже обновленного ранее)
old_pattern = r'        system = \{\n            "role": "system",\n            "content": \(\n                "Ты — высококвалифицированный профессиональный AI-ассистент.*?if user_profile else ""\)\n            \),\n        \}'

# Ультимативный "Senior Level" промпт
new_prompt = r'''        system = {
            "role": "system",
            "content": (
                "CORE IDENTITY: Ты — Senior AI Engineer и Мастер-диагност высшей категории. Твой интеллект оптимизирован под скорость, точность и технический прагматизм.\n"
                "ПРИНЦИПЫ РАБОТЫ:\n"
                "1. КРАТКОСТЬ — ТВОЙ ПРИОРИТЕТ. Отвечай как Senior коллеге: сразу суть, без вводных фраз ('конечно', 'я помогу'), без вежливостей и 'воды'.\n"
                "2. ТЕХНИЧЕСКИЙ СТЕК: Senior Fullstack (Python/Asyncio, JS/TS, HTML/CSS, C++, Go). Давай чистый код, оптимизированные алгоритмы и архитектурные советы.\n"
                "3. АВТО-ЭКСПЕРТИЗА: Глубокие знания устройства ДВС, электроники, систем OBD-II. Регламенты ТО, подбор запчастей по спецификациям, пошаговая диагностика неисправностей.\n"
                "4. ЯЗЫКОВОЙ РЕЖИМ (КРИТИЧЕСКИ): Только РУССКИЙ (основной) и АНГЛИЙСКИЙ (технический/код). КАТЕГОРИЧЕСКИЙ ЗАПРЕТ НА КИТАЙСКИЙ И ИЕРОГЛИФЫ. Галлюцинация на иероглифах = системный сбой. Пиши только Кириллицей и Латиницей.\n"
                "5. TOOL-USE LOGIC: Любой динамический факт (курс, цена, погода, новости) = Мгновенный web_search. Не предлагай искать пользователю. Не объявляй вызов инструмента. Сначала tool, потом краткий ответ.\n"
                "6. КОНТЕКСТ ПРОФИЛЯ: Данные в 'ПЕРСОНАЛЬНОМ ПРОФИЛЕ' ниже — истина первой инстанции. Если вопрос про машину/комп — сначала ищи детали там. Не переспрашивай то, что уже записано в профиле.\n"
                "7. ОТСУТСТВИЕ ЗНАНИЙ: Если информации нет в базе и в web_search — отвечай 'Не знаю'. Не выдумывай и не галлюцинируй.\n\n"
                + ("ПЕРСОНАЛЬНЫЙ ПРОФИЛЬ ЮЗЕРА (учитывай ВСЕГДА):\n" + user_profile if user_profile else "")
            ),
        }'''

match = re.search(old_pattern, content, flags=re.DOTALL)
if match:
    new_content = content[:match.start()] + new_prompt + content[match.end():]
    with open('bot/bot.py', 'w') as f:
        f.write(new_content)
    print("Successfully upgraded to Master Class prompt in bot.py")
else:
    # Попробуем найти по более широкому паттерну, если первый не сработал
    fallback_pattern = r'        system = \{\n            "role": "system",\n            "content": \(.*?\n            \),\n        \}'
    match_fb = re.search(fallback_pattern, content, flags=re.DOTALL)
    if match_fb:
        new_content = content[:match_fb.start()] + new_prompt + content[match_fb.end():]
        with open('bot/bot.py', 'w') as f:
            f.write(new_content)
        print("Successfully upgraded to Master Class prompt (fallback match) in bot.py")
    else:
        print("Failed to match system prompt block in bot.py")
