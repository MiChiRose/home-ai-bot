#!/bin/bash

# ultimate_llama_fix.sh — ПЕРЕХОД НА LLAMA 3.1 + ЖЕСТКИЙ ПАТЧ ЛОГИКИ
# Это финальная попытка заставить бота работать проактивно.

TARGET_DIR="/home/linuxserver/ai-assistant"

echo "=== ПЕРЕХОД НА LLAMA 3.1 + ПРИНУДИТЕЛЬНЫЙ ПОИСК ==="

# 1. Поиск папки
if [ ! -d "$TARGET_DIR" ]; then
    TARGET_DIR=$(find $(pwd) -name "ai-assistant" -type d -print -quit)
fi

if [ -z "$TARGET_DIR" ]; then echo "[ОШИБКА] Не нашел папку бота!"; exit 1; fi

# 2. Смена модели на Llama 3.1 (самая стабильная для инструментов)
echo "[1/4] Настройка Llama 3.1:8b..."
sed -i 's/MODEL_ROUTER=.*/MODEL_ROUTER=llama3.1:8b/' "$TARGET_DIR/.env"
sed -i 's/MODEL_INSTRUCT=.*/MODEL_INSTRUCT=llama3.1:8b/' "$TARGET_DIR/.env"
sed -i 's/TOOLS_MODEL=.*/TOOLS_MODEL=llama3.1:8b/' "$TARGET_DIR/.env"
sed -i 's/OLLAMA_MODEL=.*/OLLAMA_MODEL=llama3.1:8b/' "$TARGET_DIR/.env"

# 3. Принудительная инъекция "ЗАПРЕТА НА ОТКАЗЫ" в код (Hard Patch)
echo "[2/4] Прошивка MASTER-промпта в ядро..."

python3 <<EOF
import sys
from pathlib import Path

path = Path("$TARGET_DIR/tools/llm_loop.py")
content = r'''"""chat_with_tools — MASTER EDITION V4 (LLAMA)."""
from __future__ import annotations
import os
from typing import Any
import httpx
from .registry import TOOLS_SCHEMA, dispatch_tool

# УЛЬТИМАТИВНЫЙ ПРОМПТ
DEFAULT_SYSTEM_PROMPT = (
    "CORE IDENTITY: Ты — проактивный MASTER AI. Твоя задача — ДОБЫВАТЬ ФАКТЫ.\n"
    "STRICT RULE: Если вопрос про погоду, курсы валют или новости — ты ОБЯЗАН вызвать web_search.\n"
    "ТЕБЕ ЗАПРЕЩЕНО: Говорить 'не нашел', 'посмотрите сами' или давать ссылки на сайты.\n"
    "Если web_search не дал данных — измени запрос и ищи еще раз. Твоя цель — дать цифру или факт."
)

async def chat_with_tools(user_message, history=None, *, model=None, ollama_url=None, max_iters=5, system_prompt=None):
    model = model or "llama3.1:8b"
    url = (ollama_url or os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")).rstrip("/")
    sys_p = system_prompt or DEFAULT_SYSTEM_PROMPT
    msgs = [{"role": "system", "content": sys_p}]
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
            
            tool_calls = msg.get("tool_calls") or []
            if not tool_calls: return msg.get("content", ""), msgs
            
            for tc in tool_calls:
                fn = tc.get("function", {})
                name, args = fn.get("name", ""), fn.get("arguments", {})
                print(f"--- [FORCE SEARCH] Вызываю {name} ---")
                res = await dispatch_tool(name, args)
                msgs.append({"role": "tool", "tool_call_id": tc.get("id", name), "name": name, "content": res})
        return "[ошибка итераций]", msgs
'''
path.write_text(content, encoding="utf-8")
EOF

# 4. Очистка и перезагрузка
echo "[3/4] Сброс системных служб и Ollama..."
sudo systemctl stop home-ai-bot.service 2>/dev/null
sudo systemctl disable home-ai-bot.service 2>/dev/null
sudo systemctl restart ollama
sudo pkill -9 -f "bot.py"
sleep 2

# 5. Обновленный скрипт логов
echo "[4/4] Обновление send_bot_logs.sh..."
cat <<'EOF' > "$TARGET_DIR/send_bot_logs_v2.sh"
#!/bin/bash
TARGET_DIR="/home/linuxserver/ai-assistant"
TOKEN=$(grep "^BOT_TOKEN=" "$TARGET_DIR/.env" | cut -d= -f2 | tr -d '\r\t "')
ADMIN=$(grep "^ADMIN_USER_IDS=" "$TARGET_DIR/.env" | cut -d= -f2 | cut -d, -f1 | tr -d '\r\t "')
LOGS=$(tail -n 30 "$TARGET_DIR/logs/bot-stderr.log" 2>/dev/null)
curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$ADMIN" -d "text=LOGS:
$LOGS" > /dev/null
echo "[OK] Логи ушли в ТГ."
EOF
chmod +x "$TARGET_DIR/send_bot_logs_v2.sh"

echo ""
echo "=== ГОТОВО! МОДЕЛЬ LLAMA 3.1 УСТАНОВЛЕНА ==?"
echo "Запусти бота вручную:"
echo "cd $TARGET_DIR && source .venv/bin/activate && python3 bot/bot.py"
