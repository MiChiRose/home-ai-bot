"""chat_with_tools — главная функция, которую дёргает bot.py. Сама гоняет tool-loop."""
from __future__ import annotations
import os
from typing import Any

import httpx

from .registry import TOOLS_SCHEMA, dispatch_tool


DEFAULT_SYSTEM_PROMPT = (
    "CORE IDENTITY: Ты — проактивный и высококвалифицированный AI-ассистент. Твоя цель — максимально полно и точно отвечать на любые запросы пользователя, используя доступные инструменты.\n"
    "PROACTIVE BEHAVIOR: Никогда не проси пользователя 'проверить самостоятельно' или 'посмотреть на сайтах'. Если тебе нужны данные (курс валют, погода, новости и т.д.) — ОБЯЗАТЕЛЬНО используй инструмент `web_search`. Если запрос касается прошлого (например, погода 2 дня назад), используй `web_search` для поиска исторических данных.\n"
    "SKILLS: Мастер поиска в интернете, эксперт по Python, JS, C++, Go, автомеханике и аналитике. Твои ответы должны быть содержательными, полезными и технически грамотными.\n"
    "ЯЗЫК: Отвечай на языке запроса пользователя (преимущественно РУССКИЙ). ИЕРОГЛИФЫ ЗАПРЕЩЕНЫ. Будь вежлив, но по делу, без лишней воды."
)


async def chat_with_tools(
    user_message: str,
    history: list[dict[str, Any]] | None = None,
    *,
    model: str | None = None,
    ollama_url: str | None = None,
    max_iters: int | None = None,
    system_prompt: str | None = None,
) -> tuple[str, list[dict[str, Any]]]:
    """
    Запускает chat-completion с tool-loop. Возвращает (final_text, updated_history).
    history передавай без system message — он добавится автоматически.
    """
    # Подхватываем модель из стандартных у тебя имён переменных в .env (см. swap-models.sh):
    # сначала явный override, затем MODEL_ROUTER (если ты роутишь tool calls на отдельную модель),
    # затем MODEL_INSTRUCT (instruct модель — её и используй для tools по умолчанию),
    # затем generic OLLAMA_MODEL, затем разумный fallback.
    model = (
        model
        or os.environ.get("TOOLS_MODEL")
        or os.environ.get("MODEL_ROUTER")
        or os.environ.get("MODEL_INSTRUCT")
        or os.environ.get("OLLAMA_MODEL")
        or "gemma4:e4b"
    )
    ollama_url = (ollama_url or os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")).rstrip("/")
    max_iters  = max_iters or int(os.environ.get("MAX_TOOL_ITERATIONS", "5"))
    sys_prompt = system_prompt or DEFAULT_SYSTEM_PROMPT

    msgs: list[dict[str, Any]] = [{"role": "system", "content": sys_prompt}]
    if history:
        msgs.extend(history)
    msgs.append({"role": "user", "content": user_message})

    async with httpx.AsyncClient(timeout=httpx.Timeout(300.0, read=300.0)) as client:
        for iteration in range(max_iters):
            payload = {
                "model": model,
                "messages": msgs,
                "tools": TOOLS_SCHEMA,
                "stream": False,
                "options": {"temperature": 0.1},
            }
            r = await client.post(f"{ollama_url}/api/chat", json=payload)
            r.raise_for_status()
            data = r.json()
            msg = data.get("message", {}) or {}
            msgs.append(msg)

            tool_calls = msg.get("tool_calls") or []
            if not tool_calls:
                return msg.get("content", "") or "", msgs

            for tc in tool_calls:
                fn = (tc.get("function") or {})
                name = fn.get("name", "")
                args = fn.get("arguments", {})
                result = await dispatch_tool(name, args)
                msgs.append({
                    "role": "tool",
                    "tool_call_id": tc.get("id", name),
                    "name": name,
                    "content": result,
                })

        return "[превышен лимит итераций tool-loop — упростите запрос]", msgs
