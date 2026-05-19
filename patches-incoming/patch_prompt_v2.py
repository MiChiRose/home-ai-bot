import os
import shutil
import sys
from pathlib import Path

# ЖЕСТКАЯ КОНФИГУРАЦИЯ ПУТЕЙ
TARGET_BASE = Path("/home/linuxserver/ai-assistant")
LLM_LOOP_PATH = TARGET_BASE / "tools" / "llm_loop.py"

def apply_patch():
    print(f"--- НАЧИНАЮ ЖЕСТКУЮ ПЕРЕПРОШИВКУ ПУТИ: {TARGET_BASE} ---")
    
    if not TARGET_BASE.exists():
        print(f"[КРИТИЧЕСКАЯ ОШИБКА] Директория {TARGET_BASE} не найдена!")
        print("Проверьте, правильно ли указан путь к боту.")
        return

    # Новое содержимое llm_loop.py с ГИПЕР-ПРОМПТОМ
    content = r'''"""chat_with_tools — главная функция. ПЕРЕПРОШИТО V2."""
from __future__ import annotations
import os
from typing import Any
import httpx
from .registry import TOOLS_SCHEMA, dispatch_tool

# ГИПЕР-ПРОМПТ: ЗАПРЕЩАЕТ ОТКАЗЫ ОТ ПОИСКА
DEFAULT_SYSTEM_PROMPT = (
    "CORE IDENTITY: Ты — проактивный MASTER AI. Твоя задача — добывать факты любой ценой.\n"
    "STRICT RULE 1: Если запрос содержит вопросы о погоде, курсах валют, новостях или событиях (СЕГОДНЯ, ВЧЕРА, 2 ДНЯ НАЗАД, В ПЯТНИЦУ) — ты ОБЯЗАН вызвать функцию `web_search`.\n"
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

    # Запись файла
    try:
        with open(LLM_LOOP_PATH, "w", encoding="utf-8") as f:
            f.write(content)
        print(f"[OK] Файл {LLM_LOOP_PATH} успешно обновлен.")
    except Exception as e:
        print(f"[ОШИБКА] Не удалось записать файл: {e}")
        return

    # Остановка всех копий бота
    print("[!] Останавливаю все старые процессы бота...")
    os.system("pkill -9 -f 'python3.*bot.py'")
    
    print("\n--- ВСЁ ГОТОВО ---")
    print(f"1. Зайди в папку: cd {TARGET_BASE}")
    print(f"2. Запусти бота: source .venv/bin/activate && python3 bot/bot.py")

if __name__ == "__main__":
    apply_patch()
