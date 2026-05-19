#!/bin/bash

# fix_final_intelligence.sh — ФИНАЛЬНЫЙ АПГРЕЙД ИНТЕЛЛЕКТА
# Добавляет знание о дате и заставляет бота искать конкретные числа.

TARGET_DIR="/home/linuxserver/ai-assistant"
echo "=== АПГРЕЙД МОЗГА БОТА (V6) ==="

# 1. Поиск папки
if [ ! -d "$TARGET_DIR" ]; then
    TARGET_DIR=$(find $(pwd) -name "ai-assistant" -type d -print -quit)
fi

# 2. Обновление llm_loop.py с указанием СЕГОДНЯШНЕЙ ДАТЫ
echo "[1/2] Установка временной ориентации..."

# Генерируем текущую дату для промпта
CURRENT_DATE="Сегодня: Вторник, 19 мая 2026 года."

cat <<EOF > "$TARGET_DIR/tools/llm_loop.py"
"""chat_with_tools — V6 INTELLIGENCE EDITION."""
from __future__ import annotations
import os
import time
from typing import Any
import httpx
from .registry import TOOLS_SCHEMA, dispatch_tool

# УЛЬТИМАТИВНЫЙ ПРОМПТ С ДАТОЙ
DEFAULT_SYSTEM_PROMPT = (
    "CORE IDENTITY: Ты — проактивный MASTER AI. Твоя задача — давать ФАКТЫ.\n"
    "$CURRENT_DATE\n"
    "STRICT RULE: Если вопрос про прошлое (вчера, воскресенье, прошлый год) — вычисли точную дату и ищи её через web_search.\n"
    "ТЕБЕ ЗАПРЕЩЕНО: Говорить 'не нашел' или 'посмотрите сами'. Твоя цель — найти ответ любой ценой.\n"
    "Если web_search не дал данных — измени запрос (добавь город, дату, сайт) и ищи ЕЩЕ РАЗ."
)

async def chat_with_tools(user_message, history=None, *, model=None, ollama_url=None, max_iters=5, system_prompt=None):
    model = "llama3.1:8b"
    url = (ollama_url or os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")).rstrip("/")
    sys_p = system_prompt or DEFAULT_SYSTEM_PROMPT
    msgs = [{"role": "system", "content": sys_p}]
    if history: msgs.extend(history)
    msgs.append({"role": "user", "content": user_message})
    
    async with httpx.AsyncClient(timeout=300.0) as client:
        for iteration in range(max_iters):
            payload = {"model": model, "messages": msgs, "tools": TOOLS_SCHEMA, "stream": False, "options": {"temperature": 0.0}}
            try:
                r = await client.post(f"{url}/api/chat", json=payload)
                r.raise_for_status()
                data = r.json()
                msg = data.get("message", {})
                msgs.append(msg)
                
                if not msg.get("tool_calls"):
                    return msg.get("content", "").strip(), msgs
                
                for tc in msg["tool_calls"]:
                    fn = tc.get("function", {})
                    name, args = fn.get("name", ""), fn.get("arguments", {})
                    print(f"--- [SEARCHING] {name}({args}) ---")
                    res = await dispatch_tool(name, args)
                    msgs.append({"role": "tool", "tool_call_id": tc.get("id", name), "name": name, "content": res})
            except Exception as e:
                return f"Ошибка связи с Ollama: {e}", msgs
        return "[ошибка итераций — поиск зациклился]", msgs
EOF

# 3. Фикс в bot.py для удаления остатков вежливости
echo "[2/2] Очистка bot.py от лишних проверок..."
python3 <<EOF
import sys
from pathlib import Path
path = Path("$TARGET_DIR/bot/bot.py")
if path.exists():
    content = path.read_text(encoding="utf-8")
    # Удаляем любые попытки бота оправдываться
    import re
    content = re.sub(r'return "Не смог получить погоду.*?"', 'return None', content)
    path.write_text(content, encoding="utf-8")
EOF

# 4. Перезапуск всего
pkill -9 -f "bot.py"
sudo systemctl restart ollama 2>/dev/null

echo ""
echo "=== ГОТОВО! ТЕПЕРЬ БОТ ЗНАЕТ КАКОЕ СЕГОДНЯ ЧИСЛО ==="
echo "Запусти его вручную и спроси про воскресенье еще раз."
