"""chat_with_tools — MASTER EDITION V4 (LLAMA)."""
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
