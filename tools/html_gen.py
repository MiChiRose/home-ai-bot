"""HTML page generator — превращает текстовое описание в одностраничный HTML
с inline CSS, без внешних зависимостей, без JS (кроме случаев когда юзер явно
просит интерактив).

Используется через registry.py:generate_html_page. Файл сохраняется в
sandbox/output/{filename}.html — bot.py auto-ship pickнет .html при наличии
intent-keyword (сайт/страница/landing/html) в user_text.

Modeль для генерации берётся из HTML_GEN_MODEL env (fallback MODEL_INSTRUCT
из .env). Температура 0.3 — баланс между креативностью и валидностью HTML.
"""

from __future__ import annotations

import os
import re
import time
from pathlib import Path

import httpx


OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434").rstrip("/")
HTML_GEN_MODEL = os.environ.get(
    "HTML_GEN_MODEL",
    os.environ.get("MODEL_INSTRUCT") or "llama3.1:8b",
)
HTML_GEN_TIMEOUT_SECONDS = int(os.environ.get("HTML_GEN_TIMEOUT_SECONDS", "180"))


PROMPT_TEMPLATE = """Ты — frontend-разработчик. Сгенерируй ОДНОСТРАНИЧНЫЙ HTML по описанию.

ТРЕБОВАНИЯ (строго):
- Один файл: <!DOCTYPE html> + <html> + <head> с inline <style> + <body>.
- Современный дизайн: flexbox/grid, mobile-first, адаптив.
- Семантический HTML5: header / main / section / footer где уместно.
- Inline CSS в <style> внутри <head>. БЕЗ внешних ссылок на .css.
- БЕЗ внешних изображений (используй emoji 🎨🚀✨ или inline SVG для иконок).
- БЕЗ JavaScript если можно обойтись CSS hover/transitions (если юзер ЯВНО просит интерактив — добавь минимальный JS внутри <script>, никаких CDN).
- Используй современные паттерны: gradient backgrounds, rounded corners, subtle shadows, generous whitespace.
- Шрифты: только system-stack (`font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;`).
- Контент на языке юзера (если описание на русском — страница на русском).

ЗАГОЛОВОК СТРАНИЦЫ (тег <title>): {title}

ОПИСАНИЕ ОТ ЮЗЕРА:
{content_brief}

ВАЖНО — ФОРМАТ ОТВЕТА: верни СТРОГО только HTML код. Никаких markdown-блоков ```html, никаких комментариев перед или после, никаких пояснений. Просто HTML, начиная с <!DOCTYPE html> и заканчивая </html>."""


_FENCE_RE = re.compile(r"^\s*```(?:html|HTML)?\s*\n", re.MULTILINE)
_FENCE_END_RE = re.compile(r"\n```\s*$", re.MULTILINE)


async def generate_html_page(
    title: str,
    content_brief: str,
    filename: str = "page",
) -> str:
    """Generate single-page HTML from a brief and save to sandbox/output/.

    Args:
        title: HTML <title> tag content.
        content_brief: Free-form description of what the page should contain.
        filename: Output filename without extension (sanitized).

    Returns:
        Absolute path to the generated .html file as string.

    Raises:
        httpx.HTTPStatusError on Ollama failure.
        OSError on filesystem failure.
    """
    sandbox = Path(os.environ.get("BOT_SANDBOX", str(Path.home() / "bot-workspace")))
    output = sandbox / "output"
    output.mkdir(parents=True, exist_ok=True)

    # Sanitize filename
    safe_name = re.sub(r"[^A-Za-z0-9_-]+", "_", (filename or "page").strip()).strip("_") or "page"
    if len(safe_name) > 60:
        safe_name = safe_name[:60]
    target = output / f"{safe_name}.html"

    prompt = PROMPT_TEMPLATE.format(title=title, content_brief=content_brief)

    async with httpx.AsyncClient(timeout=httpx.Timeout(HTML_GEN_TIMEOUT_SECONDS)) as client:
        response = await client.post(
            f"{OLLAMA_URL}/api/generate",
            json={
                "model": HTML_GEN_MODEL,
                "prompt": prompt,
                "stream": False,
                "options": {"temperature": 0.3, "num_predict": 4096},
                "keep_alive": "5m",
            },
        )
        response.raise_for_status()
        data = response.json()
        html_raw = (data.get("response") or "").strip()

    # Strip markdown fences if model wrapped output
    html = _FENCE_RE.sub("", html_raw)
    html = _FENCE_END_RE.sub("", html)
    html = html.strip()

    # If model returned non-HTML — wrap in minimal HTML envelope (defensive)
    lowered = html.lower().lstrip()
    if not (lowered.startswith("<!doctype") or lowered.startswith("<html")):
        # Try to find <html…> tag mid-string
        m = re.search(r"<html[\s>]", html, re.IGNORECASE)
        if m:
            html = html[m.start():]
        else:
            # Last-resort: wrap text content into minimal valid page
            from html import escape as _html_escape
            safe_title = _html_escape(title or "Generated page")
            safe_body = _html_escape(html or "(пустой ответ модели)").replace("\n", "<br>")
            html = (
                "<!DOCTYPE html>\n"
                f"<html lang='ru'><head><meta charset='utf-8'>"
                f"<title>{safe_title}</title>"
                "<style>body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;"
                "max-width:720px;margin:40px auto;padding:0 20px;line-height:1.6;color:#222;}"
                "h1{color:#0066cc;}</style></head>"
                f"<body><h1>{safe_title}</h1><p>{safe_body}</p></body></html>"
            )

    target.write_text(html, encoding="utf-8")
    return str(target)
