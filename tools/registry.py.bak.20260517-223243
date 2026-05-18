"""OpenAI-format tools schema + async dispatcher. bot.py импортирует TOOLS_SCHEMA и dispatch_tool."""
from __future__ import annotations
import json
from typing import Any

from .file_ops import read_file, write_file, list_dir, search_files
from .document_ops import read_pdf, read_docx, write_docx
from .image_gen import generate_image
from .web_search import web_search


TOOLS_SCHEMA: list[dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": "web_search",
            "description": "Поиск актуальной информации в интернете. Использовать, когда нужны свежие данные, новости, цены, факты после твоего knowledge cutoff.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query":       {"type": "string", "description": "Поисковый запрос на любом языке."},
                    "max_results": {"type": "integer", "description": "Сколько результатов вернуть (1-10).", "default": 5},
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Прочитать текстовый файл из рабочей песочницы пользователя.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Относительный путь внутри sandbox, например 'notes/idea.md'."},
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": "Записать (перезаписать) текстовый файл в песочнице пользователя. Папки создаются автоматически.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path":    {"type": "string", "description": "Относительный путь внутри sandbox."},
                    "content": {"type": "string", "description": "Содержимое файла."},
                },
                "required": ["path", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_dir",
            "description": "Получить листинг папки внутри песочницы.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Относительный путь, '.' для корня sandbox.", "default": "."},
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "search_files",
            "description": "Поиск regex-паттерна по содержимому файлов в sandbox-папке (как `grep -rE`).",
            "parameters": {
                "type": "object",
                "properties": {
                    "pattern": {"type": "string", "description": "Регулярка (Python re, IGNORECASE)."},
                    "path":    {"type": "string", "description": "Папка для поиска, '.' = корень sandbox.", "default": "."},
                },
                "required": ["pattern"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_pdf",
            "description": "Прочитать текст из PDF файла в песочнице пользователя (например из uploads/файл.pdf).",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Относительный путь к PDF внутри sandbox."},
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_docx",
            "description": "Прочитать текст из DOCX файла в песочнице пользователя.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Относительный путь к DOCX внутри sandbox."},
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "write_docx",
            "description": "Создать DOCX файл в песочнице пользователя. По соглашению клади результат в output/ — bot.py автоматом отправит файл юзеру в Telegram. В content можно использовать markdown-like структуру: '# Заголовок 1', '## Заголовок 2', '- буллет'.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path":    {"type": "string", "description": "Куда сохранить, рекомендуется output/имя.docx"},
                    "title":   {"type": "string", "description": "Заголовок документа (попадёт как H0)."},
                    "content": {"type": "string", "description": "Содержимое. Строки с # / ## / ### становятся заголовками."},
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "generate_image",
            "description": "Сгенерировать изображение через локальный Stable Diffusion 3. Использовать когда юзер просит создать/нарисовать/сгенерировать картинку. Возвращает путь — bot.py автоматически пришлёт картинку в Telegram.",
            "parameters": {
                "type": "object",
                "properties": {
                    "prompt":          {"type": "string", "description": "Описание желаемой картинки на английском (SD понимает английский лучше). Будь конкретным: стиль, освещение, ракурс, детали."},
                    "negative_prompt": {"type": "string", "description": "Чего быть НЕ должно (default — стандартный quality-фильтр).", "default": "low quality, blurry, distorted, deformed, watermark"},
                    "width":           {"type": "integer", "description": "Ширина 512-1536. По умолчанию 1024.", "default": 1024},
                    "height":          {"type": "integer", "description": "Высота 512-1536. По умолчанию 1024.", "default": 1024},
                },
                "required": ["prompt"],
            },
        },
    },
]

_FUNCS = {
    "web_search":   web_search,
    "read_file":    read_file,
    "write_file":   write_file,
    "list_dir":     list_dir,
    "search_files": search_files,
    "read_pdf":     read_pdf,
    "read_docx":    read_docx,
    "write_docx":   write_docx,
    "generate_image": generate_image,
}


async def dispatch_tool(name: str, arguments: Any) -> str:
    """Вызывает tool по имени. arguments — dict (Ollama уже распарсил) или JSON-строка (на всякий случай)."""
    if name not in _FUNCS:
        return f"[dispatch_tool ERROR] неизвестный tool '{name}'. Доступные: {list(_FUNCS)}"
    if isinstance(arguments, str):
        try:
            arguments = json.loads(arguments) if arguments.strip() else {}
        except json.JSONDecodeError as e:
            return f"[dispatch_tool ERROR] невалидный JSON в arguments: {e}"
    if not isinstance(arguments, dict):
        return f"[dispatch_tool ERROR] arguments должен быть object, получили {type(arguments).__name__}"
    try:
        result = await _FUNCS[name](**arguments)
    except TypeError as e:
        return f"[dispatch_tool ERROR] {name}: неверные аргументы — {e}"
    except PermissionError as e:
        return f"[dispatch_tool ERROR] {name}: {e}"
    except Exception as e:
        return f"[dispatch_tool ERROR] {name}: непредвиденная ошибка — {type(e).__name__}: {e}"
    return result if isinstance(result, str) else json.dumps(result, ensure_ascii=False)
