"""chat_with_tools — главная функция. ПЕРЕПРОШИТО V3 (BASH-PATCH)."""
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
