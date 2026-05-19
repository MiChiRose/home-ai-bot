"""chat_with_tools — V9 REAL-TIME EDITION."""
from __future__ import annotations
import os
from typing import Any
import httpx
from .registry import TOOLS_SCHEMA, dispatch_tool

# ПРОМПТ С РЕАЛЬНОЙ ДАТОЙ
DEFAULT_SYSTEM_PROMPT = (
    "Сегодняшняя дата: Среда, 20 мая 2026 года (числом: 20.05.2026).\n"
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
