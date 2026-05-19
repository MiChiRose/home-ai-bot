#!/bin/bash

# nuclear_logic_fix.sh — УДАЛЕНИЕ ВСЕХ ТОРМОЗОВ
# Этот скрипт заменяет сложный системный промпт на одну жесткую команду.

TARGET_DIR="/home/linuxserver/ai-assistant"
echo "=== АТОМАРНАЯ ПЕРЕПРОШИВКА ЛОГИКИ ==="

# 1. Поиск папки
if [ ! -d "$TARGET_DIR" ]; then
    TARGET_DIR=$(find $(pwd) -name "ai-assistant" -type d -print -quit)
fi

# 2. Жесткая инъекция в bot.py (заменяем огромный system prompt на короткий)
echo "[1/2] Очистка инструкций бота от пассивности..."

python3 <<EOF
import sys
from pathlib import Path

path = Path("$TARGET_DIR/bot/bot.py")
if not path.exists():
    print("Файл bot.py не найден!")
    sys.exit(1)

content = path.read_text(encoding="utf-8")

# Находим огромный блок system prompt и заменяем его
import re
new_system_content = r'''
        system = {
            "role": "system",
            "content": (
                "Ты — проактивный AI-терминатор поиска. Твоя задача: давать ФАКТЫ.\n"
                "ЗАПРЕЩЕНО: Говорить 'не нашел', 'проверьте сами', 'посмотрите на сайте'.\n"
                "ОБЯЗАТЕЛЬНО: Если нужен курс, погода или факт — ТЫ ВСЕГДА ВЫЗЫВАЕШЬ web_search.\n"
                "Если web_search не дал данных с первого раза — пробуй еще раз с другим запросом.\n"
                "Отвечай КРАТКО, только цифрами и фактами. Без лишней вежливости и воды.\n"
                "ЯЗЫК: СТРОГО РУССКИЙ."
            ),
        }
'''

# Заменяем блок определения system переменной
# Ищем от 'system = {' до 'messages_for_llm ='
pattern = re.compile(r'system = \{.*?\}\n\s+user_text_for_llm =', re.DOTALL)
if pattern.search(content):
    content = pattern.sub(new_system_content + "\n        user_text_for_llm =", content)
    path.write_text(content, encoding="utf-8")
    print("[OK] Системный промпт упрощен и ужесточен.")
else:
    print("[!] Не удалось найти блок промпта для автоматической замены. Пробую другой метод...")
    # Фолбек: просто перезапишем llm_loop еще раз с усилением
EOF

# 3. Усиление llm_loop.py (V5)
echo "[2/2] Усиление MASTER-контроллера..."

cat <<'EOF' > "$TARGET_DIR/tools/llm_loop.py"
"""chat_with_tools — V5 NUCLEAR EDITION."""
from __future__ import annotations
import os
from typing import Any
import httpx
from .registry import TOOLS_SCHEMA, dispatch_tool

DEFAULT_SYSTEM_PROMPT = "ТЫ ОБЯЗАН ИСПОЛЬЗОВАТЬ web_search ДЛЯ ЛЮБЫХ ФАКТОВ. ЗАПРЕЩЕНО ГОВОРИТЬ 'НЕ ЗНАЮ' ИЛИ 'ПОСМОТРИТЕ САМИ'."

async def chat_with_tools(user_message, history=None, *, model=None, ollama_url=None, max_iters=5, system_prompt=None):
    model = "llama3.1:8b"
    url = (ollama_url or os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")).rstrip("/")
    msgs = [{"role": "system", "content": DEFAULT_SYSTEM_PROMPT}]
    if history: msgs.extend(history)
    msgs.append({"role": "user", "content": user_message})
    
    async with httpx.AsyncClient(timeout=300.0) as client:
        for _ in range(max_iters):
            payload = {"model": model, "messages": msgs, "tools": TOOLS_SCHEMA, "stream": False, "options": {"temperature": 0.0}}
            r = await client.post(f"{url}/api/chat", json=payload)
            r.raise_for_status()
            data = r.json()
            msg = data.get("message", {})
            msgs.append(msg)
            if not msg.get("tool_calls"): return msg.get("content", ""), msgs
            for tc in msg["tool_calls"]:
                fn = tc.get("function", {})
                name, args = fn.get("name", ""), fn.get("arguments", {})
                print(f"--- [NUCLEAR SEARCH] {name}({args}) ---")
                res = await dispatch_tool(name, args)
                msgs.append({"role": "tool", "tool_call_id": tc.get("id", name), "name": name, "content": res})
        return "Ошибка: слишком много попыток поиска.", msgs
EOF

# 4. Очистка
pkill -9 -f "bot.py"
sudo systemctl restart ollama 2>/dev/null

echo ""
echo "=== ВСЁ ГОТОВО! БОТ ПЕРЕПРОШИТ ==="
echo "Теперь запусти бота вручную:"
echo "cd $TARGET_DIR && source .venv/bin/activate && python3 bot/bot.py"
