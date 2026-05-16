# Интеграция tools в bot.py

В одном handler'е заменяешь свой текущий «отправь сообщение → вытащи ответ из Ollama → верни» на вызов `chat_with_tools`.

## aiogram 3.x пример

```python
from aiogram import Router, types
from aiogram.filters import CommandStart
from tools.llm_loop import chat_with_tools

router = Router()

# In-memory история на user_id. Для prod лучше Redis / sqlite — это P4.
_HISTORY: dict[int, list[dict]] = {}

@router.message()
async def on_text(message: types.Message) -> None:
    if message.from_user is None or message.text is None:
        return
    # whitelist уже проверен middleware'ом, который ты сделал в P1

    uid = message.from_user.id
    hist = _HISTORY.setdefault(uid, [])
    try:
        reply_text, new_hist = await chat_with_tools(message.text, hist)
    except Exception as e:
        await message.answer(f"Ошибка LLM: {e}")
        return

    # обрезаем историю чтобы не раздувать контекст (последние 20 сообщений)
    _HISTORY[uid] = new_hist[-20:]
    await message.answer(reply_text or "(пустой ответ)")
```

## aiogram 2.x пример

```python
from aiogram import types
from tools.llm_loop import chat_with_tools

_HISTORY: dict[int, list[dict]] = {}

@dp.message_handler()
async def on_text(message: types.Message):
    uid = message.from_user.id
    hist = _HISTORY.setdefault(uid, [])
    reply_text, new_hist = await chat_with_tools(message.text, hist)
    _HISTORY[uid] = new_hist[-20:]
    await message.answer(reply_text or "(пустой ответ)")
```

## Что делать дальше

1. Активируй venv (если используешь) и поставь зависимости:
   ```
   cd ~/ai-assistant
   source .venv/bin/activate   # или какой у тебя
   pip install -r requirements.txt
   ```
2. Скопируй блок из `.env.example.tools` в `~/ai-assistant/.env`. Если выбрал `tavily` — заполни `TAVILY_API_KEY` с tavily.com (free 1000/мес).
3. `tools/llm_loop.py` сам подхватит модель из твоих `MODEL_ROUTER` / `MODEL_INSTRUCT`, отдельно ничего прописывать не надо.
4. Рестарт твоего user-юнита:
   ```
   systemctl --user restart home-ai-bot.service
   journalctl --user -u home-ai-bot.service -f
   ```
5. В Telegram пиши боту:
   - «Какой сейчас курс доллара в Беларуси?» → должен вызвать `web_search`.
   - «Запиши в файл notes/idea.md текст: blah» → `write_file`.
   - «Покажи что у меня в папке notes» → `list_dir`.

## Если модель плохо вызывает tools

- У тебя по swap-models.sh стоит `gemma4:e4b` — Gemma 4 поддерживает function calling, но менее агрессивно чем Qwen 2.5-Instruct. Если ловишь много мисов:
  - Усиль system prompt в `tools/llm_loop.py` — добавь 1-2 few-shot примера правильного вызова.
  - Снизь `temperature` в `llm_loop.py` с 0.3 до 0.1 — для tool calling детерминированность важнее креатива.
  - Если совсем не справляется — для tool-loop можно временно использовать отдельную instruct-модель через `TOOLS_MODEL=qwen2.5:7b-instruct` в `.env` (Qwen 2.5 нативно заточен под Hermes tool format и работает заметно стабильнее на 7B). Pull один раз — `ollama pull qwen2.5:7b-instruct`.
- Если хочешь — можно в P4 настроить роутер так чтобы tools уходили на одну модель, а свободный диалог на gemma4. Но это уже не P2.

## Безопасность

- Песочница: модель видит только содержимое `$BOT_SANDBOX`. `read_file('/etc/passwd')` упадёт с PermissionError.
- `write_file` перезаписывает без подтверждения — это by design, чтобы не плодить tool round-trips. Если боишься за свои файлы — держи sandbox в отдельной папке без чего-либо ценного.
- `.env` и сам репо вне sandbox — недоступны для модели.
