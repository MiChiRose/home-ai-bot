"""Web search tool. Провайдер выбирается по env WEB_SEARCH_PROVIDER (tavily|ddg)."""
from __future__ import annotations
import asyncio
import os
from typing import Any

import httpx


async def _search_tavily(query: str, max_results: int) -> str:
    api_key = os.environ.get("TAVILY_API_KEY")
    if not api_key:
        return "[web_search ERROR] TAVILY_API_KEY не задан в .env"
    payload: dict[str, Any] = {
        "api_key": api_key,
        "query": query,
        "max_results": max_results,
        "search_depth": "basic",
        "include_answer": True,
    }
    try:
        async with httpx.AsyncClient(timeout=30) as c:
            r = await c.post("https://api.tavily.com/search", json=payload)
            r.raise_for_status()
            data = r.json()
    except httpx.HTTPError as e:
        return f"[web_search ERROR Tavily] {e}"

    lines: list[str] = []
    if ans := data.get("answer"):
        lines.append(f"Сводка: {ans}")
    for i, res in enumerate(data.get("results", []), 1):
        title = res.get("title", "").strip()
        url = res.get("url", "")
        snippet = (res.get("content") or "").strip().replace("\n", " ")[:400]
        lines.append(f"{i}. {title}\n   {url}\n   {snippet}")
    return "\n\n".join(lines) if lines else "[web_search] нет результатов"


async def _search_ddg(query: str, max_results: int) -> str:
    # duckduckgo-search — sync API, оборачиваем в thread
    try:
        from ddgs import DDGS
    except ImportError:
        return "[web_search ERROR] pip install ddgs"

    def _do() -> list[dict]:
        with DDGS() as d:
            return list(d.text(query, max_results=max_results))

    try:
        rows = await asyncio.to_thread(_do)
    except Exception as e:
        return f"[web_search ERROR DDG] {e}"

    lines: list[str] = []
    for i, r in enumerate(rows, 1):
        title = (r.get("title") or "").strip()
        href = r.get("href") or r.get("url") or ""
        body = (r.get("body") or "").strip().replace("\n", " ")[:400]
        lines.append(f"{i}. {title}\n   {href}\n   {body}")
    return "\n\n".join(lines) if lines else "[web_search] нет результатов"


async def web_search(query: str, max_results: int = 5) -> str:
    """Поиск в интернете. Возвращает текст с топ-N результатами (markdown-ish)."""
    provider = os.environ.get("WEB_SEARCH_PROVIDER", "tavily").lower()
    max_results = max(1, min(int(max_results), 10))
    if provider == "tavily":
        return await _search_tavily(query, max_results)
    if provider == "ddg":
        return await _search_ddg(query, max_results)
    return f"[web_search ERROR] неизвестный провайдер: {provider}"
