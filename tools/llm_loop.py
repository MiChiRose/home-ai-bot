"""chat_with_tools — V8 ULTIMATE EDITION."""
from __future__ import annotations
import os
import time
from typing import Any
import httpx
from .registry import TOOLS_SCHEMA, dispatch_tool

# САМЫЙ ЖЕСТКИЙ ПРОМПТ
DEFAULT_SYSTEM_PROMPT = (
    "Сегодня: Вторник, 19 мая 2026 года.\n"
    "ТЫ — ПРОАКТИВНЫЙ МАСТЕР ДАННЫХ. Тебе ЗАПРЕЩЕНО ошибаться в цифрах.\n"
    "ПРАВИЛО ПОГОДЫ: Если ищешь погоду в прошлом (например, 17 мая) — ОБЯЗАТЕЛЬНО проверяй год и месяц в результатах поиска. "
    "Если видишь -2 градуса в мае — значит это ошибка поиска, ИЩИ ЕЩЕ РАЗ с уточнение 'архив погоды' или 'история погоды'.\n"
    "ИНСТРУМЕНТ find_image: Если просят 'найди картинку жирафа' — вызывай find_image(query='жираф').\n"
    "ТЕБЕ ЗАПРЕЩЕНО: Говорить 'не нашел' или 'посмотрите сами'. Ищи пока не найдешь факт."
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
            r = await client.post(f"{url}/api/chat", json=payload)
            msg = r.json().get("message", {})
            msgs.append(msg)
            if not msg.get("tool_calls"):
                content = msg.get("content", "").strip()
                if any(x in content.lower() for x in ["извините", "не нашел", "проверьте"]):
                    msgs.append({"role": "user", "content": "ОШИБКА: Ты не нашел факт. Попробуй поиск еще раз с ДРУГИМ запросом!"})
                    continue
                return content, msgs
            for tc in msg["tool_calls"]:
                fn = tc.get("function", {})
                name, args = fn.get("name", ""), fn.get("arguments", {})
                print(f"--- [TOOL CALL] {name}({args}) ---")
                res = await dispatch_tool(name, args)
                msgs.append({"role": "tool", "tool_call_id": tc.get("id", name), "name": name, "content": res})
        return "Ошибка: не удалось найти данные.", msgs
