"""Tool для поиска картинок в интернете через DuckDuckGo."""
from __future__ import annotations
import asyncio
import os
import random
import httpx
from pathlib import Path

async def find_image(query: str) -> str:
    """Ищет картинку в интернете и скачивает её в папку downloads. Возвращает путь к файлу."""
    try:
        from ddgs import DDGS
    except ImportError:
        return "[image_search ERROR] библиотека ddgs не установлена"

    def _search():
        with DDGS() as d:
            # Получаем 10 результатов и выбираем один случайный для разнообразия
            results = list(d.images(query, region='ru-ru', max_results=10))
            return results

    try:
        rows = await asyncio.to_thread(_search)
        if not rows:
            return "[image_search] ничего не найдено"
        
        # Берем случайную из первых 5 для релевантности
        img_data = random.choice(rows[:5])
        img_url = img_data.get('image')
        
        # Скачиваем файл в sandbox/downloads
        sandbox = Path.home() / "bot-workspace" / "downloads"
        sandbox.mkdir(parents=True, exist_ok=True)
        
        ext = Path(img_url).suffix.split('?')[0] or ".jpg"
        if len(ext) > 5: ext = ".jpg"
        
        fname = f"found_{int(asyncio.get_event_loop().time())}{ext}"
        local_path = sandbox / fname
        
        async with httpx.AsyncClient(timeout=20.0) as client:
            r = await client.get(img_url, follow_redirects=True)
            r.raise_for_status()
            local_path.write_bytes(r.content)
            
        return f"[IMAGE_FOUND] Файл сохранен: {local_path}"
        
    except Exception as e:
        return f"[image_search ERROR] {e}"
