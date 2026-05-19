#!/bin/bash

# patch_prompt_v3.sh — БАШ-СКРИПТ (запускать через ./patch_prompt_v3.sh)
# Он сам найдет папку ai-assistant и починит бота.

echo "--- ПОИСК И ПАТЧИНГ БОТА ---"

# 1. Пытаемся найти папку ai-assistant
# Сначала проверяем стандартный путь
TARGET_DIR="/home/linuxserver/ai-assistant"

if [ ! -d "$TARGET_DIR" ]; then
    echo "[!] Стандартный путь не найден. Ищу папку ai-assistant в текущей директории и глубже..."
    TARGET_DIR=$(find $(pwd) -name "ai-assistant" -type d -print -quit)
fi

if [ -z "$TARGET_DIR" ]; then
    echo "[КРИТИЧЕСКАЯ ОШИБКА] Не удалось найти папку ai-assistant!"
    echo "Пожалуйста, положите этот скрипт рядом с папкой бота."
    exit 1
fi

echo "[OK] Папка бота найдена: $TARGET_DIR"

# 2. Путь к файлу, который нужно починить
LLM_FILE="$TARGET_DIR/tools/llm_loop.py"

if [ ! -f "$LLM_FILE" ]; then
    echo "[ОШИБКА] Файл $LLM_FILE не найден!"
    exit 1
fi

# 3. Перезаписываем файл через Python (чтобы не было проблем с кавычками в bash)
echo "[2/3] Обновление логики (установка MASTER-промпта)..."

python3 <<EOF
import os

content = r'''"""chat_with_tools — главная функция. ПЕРЕПРОШИТО V3 (BASH-PATCH)."""
from __future__ import annotations
import os
from typing import Any
import httpx
from .registry import TOOLS_SCHEMA, dispatch_tool

# ГИПЕР-ПРОМПТ: ЗАПРЕЩАЕТ ОТКАЗЫ ОТ ПОИСКА
DEFAULT_SYSTEM_PROMPT = (
    "CORE IDENTITY: Ты — проактивный MASTER AI. Твоя задача — добывать факты любой ценой.\n"
    "STRICT RULE 1: Если запрос содержит вопросы о погоде, курсах валют, новостях или событиях (СЕГОДНЯ, ВЧЕРА, 2 ДНЯ НАЗАД, В ПЯТНИЦУ) — ты ОБЯЗАН вызвать функцию web_search.\n"
    "STRICT RULE 2: Тебе ЗАПРЕЩЕНО говорить 'я не нашел', 'посмотрите сами', 'проверьте на сайтах' ДО ТОГО как ты выполнил web_search.\n"
    "STRICT RULE 3: Если web_search вернул мало данных — попробуй другой запрос через web_search еще раз.\n"
    "ЯЗЫК: РУССКИЙ. Будь полезным инструментом, а не советчиком."
)

async def chat_with_tools(user_message: str, history: list[dict[str, Any]] | None = None, *, model: str | None = None, ollama_url: str | None = None, max_iters: int | None = None, system_prompt: str | None = None):
    model = model or os.environ.get("TOOLS_MODEL") or os.environ.get("MODEL_ROUTER") or "qwen2.5:7b-instruct"
    ollama_url = (ollama_url or os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")).rstrip("/")
    max_iters  = 5
    sys_prompt = system_prompt or DEFAULT_SYSTEM_PROMPT
    
    msgs = [{"role": "system", "content": sys_prompt}]
    if history: msgs.extend(history)
    msgs.append({"role": "user", "content": user_message})
    
    async with httpx.AsyncClient(timeout=300.0) as client:
        for iteration in range(max_iters):
            payload = {"model": model, "messages": msgs, "tools": TOOLS_SCHEMA, "stream": False, "options": {"temperature": 0.0}}
            r = await client.post(f"{ollama_url}/api/chat", json=payload)
            r.raise_for_status()
            data = r.json()
            msg = data.get("message", {}) or {}
            msgs.append(msg)
            
            tool_calls = msg.get("tool_calls") or []
            if not tool_calls:
                return msg.get("content", "") or "", msgs
            
            for tc in tool_calls:
                fn = tc.get("function", {})
                name = fn.get("name", "")
                args = fn.get("arguments", {})
                print(f"--- [DEBUG] ВЫЗОВ ИНСТРУМЕНТА: {name} с аргументами {args} ---")
                result = await dispatch_tool(name, args)
                msgs.append({"role": "tool", "tool_call_id": tc.get("id", name), "name": name, "content": result})
        return "[превышен лимит итераций]", msgs
'''

with open("$LLM_FILE", "w", encoding="utf-8") as f:
    f.write(content)
EOF

if [ $? -eq 0 ]; then
    echo "[OK] Файл обновлен."
else
    echo "[ОШИБКА] Не удалось обновить файл."
    exit 1
fi

# 4. Остановка старых процессов
echo "[3/3] Очистка процессов бота..."
pkill -9 -f 'python3.*bot.py'
sleep 1

echo ""
echo "--- ПАТЧ ЗАВЕРШЕН ---"
echo "Чтобы запустить бота:"
echo "cd $TARGET_DIR"
echo "source .venv/bin/activate"
echo "python3 bot/bot.py"
