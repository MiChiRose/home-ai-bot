"""OpenAI-format tools schema + async dispatcher. bot.py импортирует TOOLS_SCHEMA и dispatch_tool."""
from __future__ import annotations
import json
from typing import Any

from .file_ops import read_file, write_file, list_dir, search_files
from .document_ops import read_pdf, read_docx, write_docx
from .image_gen import generate_image
from .web_search import web_search
from .html_gen import generate_html_page
from .image_search import find_image


TOOLS_SCHEMA: list[dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": "find_image",
            "description": "Найти картинку в интернете и отправить пользователю. ✅ ВЫЗЫВАТЬ если юзер просит «найди картинку», «покажи фото», «как выглядит X».",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Что искать (например 'жираф', 'горы')."},
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "web_search",
            "description": "Поиск свежих данных в интернете. ✅ ВЫЗЫВАТЬ на запросы про актуальный курс, погоду, новости, цены, события сегодня/вчера/сейчас. ❌ НЕ вызывать на общие вопросы где достаточно знаний из training data. Tool name строго `web_search` (snake_case).",
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
            "description": "Записать (перезаписать) текстовый файл в песочнице. ⚠️ ВЫЗЫВАТЬ ТОЛЬКО если юзер ЯВНО попросил сохранить что-то в файл. ЗАПРЕЩЕНО на короткие реакции / по своей инициативе. Папки создаются автоматически.",
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
            "description": "Создать DOCX-файл в песочнице. ⚠️ ВЫЗЫВАТЬ ТОЛЬКО если юзер ЯВНО попросил документ/docx/отчёт/файл/составить/подготовить. ЗАПРЕЩЕНО вызывать на короткие реакции («Супер!», «Окей», «Класс», «Спасибо», 1-2 слова восклицания) — это user reaction, не запрос на файл. Если сомневаешься — не вызывай. В content можно использовать markdown-like: '# H1', '## H2', '- буллет'.",
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
            "description": "Сгенерировать изображение через Stable Diffusion 3. ⚠️ ВЫЗЫВАТЬ ТОЛЬКО если юзер ЯВНО попросил «нарисуй», «сгенерируй картинку», «создай изображение», «нужна иллюстрация». ЗАПРЕЩЕНО вызывать на короткие реакции или без explicit запроса на визуал.",
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
    {
        "type": "function",
        "function": {
            "name": "generate_html_page",
            "description": "Сгенерировать одностраничный HTML-сайт по описанию (inline CSS, без внешних зависимостей). ✅ ВЫЗЫВАТЬ если юзер ЯВНО просит «сделай сайт/страницу/landing/HTML/одностраничник». ❌ НЕ вызывать на короткие реакции или без explicit запроса на веб-страницу.",
            "parameters": {
                "type": "object",
                "properties": {
                    "title":         {"type": "string", "description": "Заголовок страницы (тег <title>)."},
                    "content_brief": {"type": "string", "description": "Что юзер хочет видеть на странице — секции, тексты, цвета, стиль. Чем подробнее — тем лучше."},
                    "filename":      {"type": "string", "description": "Имя файла без расширения (например 'portfolio'). По умолчанию 'page'.", "default": "page"},
                },
                "required": ["title", "content_brief"],
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
    "generate_html_page": generate_html_page,
    "find_image": find_image,
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
