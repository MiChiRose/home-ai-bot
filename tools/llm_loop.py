"""chat_with_tools — V10 FINAL FIX (MEDIA + ACCURACY)."""
from __future__ import annotations
import os
from typing import Any
import httpx
from .registry import TOOLS_SCHEMA, dispatch_tool

# САМЫЙ СТРОГИЙ ПРОМПТ
DEFAULT_SYSTEM_PROMPT = (
    "Сегодня: Вторник, 19 мая 2026 года.\n"
    "ТЫ — ПРОАКТИВНЫЙ MASTER AI. Твоя цель — ДОБЫВАТЬ ФАКТЫ.\n"
    "ПРАВИЛО ПОИСКА: Если ищешь данные в прошлом — уточняй год и месяц. ОШИБКА В ЦИФРАХ НЕДОПУСТИМА.\n"
    "ИНСТРУМЕНТ find_image: Если просят картинку — ВЫЗЫВАЙ find_image.\n"
    "ЗАПРЕЩЕНО: Говорить 'не нашел' или 'посмотрите сами'. Ищи еще раз, если не получилось."
)

async def chat_with_tools(user_message, history=None, *, model=None, ollama_url=None, max_iters=10, system_prompt=None):
    model = "llama3.1:8b"
    url = (ollama_url or os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")).rstrip("/")
    sys_p = system_prompt or DEFAULT_SYSTEM_PROMPT
    msgs = [{"role": "system", "content": sys_p}]
    if history: msgs.extend(history)
    msgs.append({"role": "user", "content": user_message})
    
    found_image_path = None
    
    async with httpx.AsyncClient(timeout=300.0) as client:
        for _ in range(max_iters):
            payload = {"model": model, "messages": msgs, "tools": TOOLS_SCHEMA, "stream": False, "options": {"temperature": 0.0}}
            try:
                r = await client.post(f"{url}/api/chat", json=payload)
                r.raise_for_status()
                msg = r.json().get("message", {})
                msgs.append(msg)
                
                # Если модель закончила говорить
                if not msg.get("tool_calls"):
                    content = msg.get("content", "").strip()
                    
                    # ПРОВЕРКА НА ПУСТОЙ ОТВЕТ
                    if any(x in content.lower() for x in ["извините", "не нашел", "не могу", "проверьте"]):
                         msgs.append({"role": "user", "content": "ОШИБКА! Твой ответ бесполезен. Используй поиск еще раз с ДРУГИМИ словами. Мне нужен ФАКТ или ЦИФРА!"})
                         continue
                    
                    # ГАРАНТИЯ ДОСТАВКИ КАРТИНКИ
                    if found_image_path:
                        content += f"\n\n[IMAGE_FOUND] Файл сохранен: {found_image_path}"
                    
                    return content, msgs
                
                # Если модель вызывает инструмент
                for tc in msg["tool_calls"]:
                    fn = tc.get("function", {})
                    name, args = fn.get("name", ""), fn.get("arguments", {})
                    print(f"--- [DEBUG] ВЫПОЛНЯЮ: {name}({args}) ---")
                    res = await dispatch_tool(name, args)
                    
                    # Запоминаем путь, если это картинка
                    if "[IMAGE_FOUND]" in res:
                        import re
                        m = re.search(r"Файл сохранен: (.*)", res)
                        if m: found_image_path = m.group(1).strip()
                    
                    msgs.append({"role": "tool", "tool_call_id": tc.get("id", name), "name": name, "content": res})
            except Exception as e:
                return f"Ошибка связи: {e}", msgs
                
        return "Превышен лимит попыток поиска.", msgs
