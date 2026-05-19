#!/bin/bash

# fix_real_time.sh — Синхронизация времени и исправление поиска
# Устанавливает РЕАЛЬНУЮ дату в промпт бота.

TARGET_DIR="/home/linuxserver/ai-assistant"
echo "=== СИНХРОНИЗАЦИЯ ВРЕМЕНИ БОТА ==="

# 1. Поиск папки
if [ ! -d "$TARGET_DIR" ]; then
    TARGET_DIR=$(find $(pwd) -name "ai-assistant" -type d -print -quit)
fi

# 2. Получаем реальную дату системы
REAL_DATE=$(date +"%A, %d %B %Y года")
# Переводим день недели на русский (на всякий случай)
REAL_DATE_RU=$(date +"%d.%m.%Y")
echo "[1/2] Реальная дата системы: $REAL_DATE_RU"

# 3. Обновление llm_loop.py с ПРАВИЛЬНОЙ датой
cat <<EOF > "$TARGET_DIR/tools/llm_loop.py"
"""chat_with_tools — V9 REAL-TIME EDITION."""
from __future__ import annotations
import os
from typing import Any
import httpx
from .registry import TOOLS_SCHEMA, dispatch_tool

# ПРОМПТ С РЕАЛЬНОЙ ДАТОЙ
DEFAULT_SYSTEM_PROMPT = (
    "Сегодняшняя дата: $REAL_DATE (числом: $REAL_DATE_RU).\n"
    "ТЫ — ПРОАКТИВНЫЙ MASTER AI. Твоя задача — давать ТОЧНЫЕ ФАКТЫ.\n"
    "ПРАВИЛО ПОИСКА: Всегда уточняй год в запросе (например, 'погода Минск 17 мая 2024'), чтобы не получить старые данные.\n"
    "Если тебя просят 'найти картинку' — ОБЯЗАТЕЛЬНО используй find_image.\n"
    "ЗАПРЕЩЕНО: Говорить 'не нашел'. Ищи еще раз, меняя слова, пока не добудешь ответ."
)

async def chat_with_tools(user_message, history=None, *, model=None, ollama_url=None, max_iters=10, system_prompt=None):
    model = "llama3.1:8b"
    url = (ollama_url or os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")).rstrip("/")
    msgs = [{"role": "system", "content": DEFAULT_SYSTEM_PROMPT}]
    if history: msgs.extend(history)
    msgs.append({"role": "user", "content": user_message})
    
    async with httpx.AsyncClient(timeout=300.0) as client:
        for _ in range(max_iters):
            payload = {"model": model, "messages": msgs, "tools": TOOLS_SCHEMA, "stream": False, "options": {"temperature": 0.0}}
            try:
                r = await client.post(f"{url}/api/chat", json=payload)
                data = r.json()
                msg = data.get("message", {})
                msgs.append(msg)
                
                if not msg.get("tool_calls"):
                    content = msg.get("content", "").strip()
                    # Если бот пытается слиться — заставляем переделывать
                    if any(x in content.lower() for x in ["извините", "не нашел", "не могу", "попробуйте проверить"]):
                         msgs.append({"role": "user", "content": "Твой ответ пустой! Используй web_search еще раз, но с другими словами. Мне нужны цифры!"})
                         continue
                    return content, msgs
                
                for tc in msg["tool_calls"]:
                    fn = tc.get("function", {})
                    name, args = fn.get("name", ""), fn.get("arguments", {})
                    print(f"--- [RUNNING TOOL] {name} ---")
                    res = await dispatch_tool(name, args)
                    msgs.append({"role": "tool", "tool_call_id": tc.get("id", name), "name": name, "content": res})
            except Exception as e:
                return f"Ошибка: {e}", msgs
        return "Не удалось найти данные за 10 попыток.", msgs
EOF

# 4. Очистка
pkill -9 -f "bot.py"

echo ""
echo "=== ГОТОВО! ДАТА СИНХРОНИЗИРОВАНА ==="
echo "Запускай бота: ./restart_bot.sh"
