"""chat_with_tools — главная функция, которую дёргает bot.py. Сама гоняет tool-loop."""
from __future__ import annotations
import os
from typing import Any

import httpx

from .registry import TOOLS_SCHEMA, dispatch_tool


DEFAULT_SYSTEM_PROMPT = (
    "Ты — полезный AI-ассистент с инструментами. У тебя есть доступ к: "
    "web_search (актуальный интернет), read_file/write_file/list_dir/search_files (файлы в личной песочнице пользователя). "
    "Используй инструменты, когда они уместны. Передавай аргументы строго по JSON-схеме. "
    "Не выдумывай содержимое файлов и веб-страниц — если не вызвал tool, не утверждай факт. "
    "Отвечай по-русски, кратко и по делу."
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
