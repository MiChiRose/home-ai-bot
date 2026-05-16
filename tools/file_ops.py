"""File operations внутри sandbox. Все пути проходят через resolve_in_sandbox()."""
from __future__ import annotations
import asyncio
import re
from pathlib import Path

from .sandbox import resolve_in_sandbox, sandbox_root


MAX_READ_BYTES = 256 * 1024   # 256 KB — чтобы не залить контекст модели
MAX_LIST_ENTRIES = 200


async def read_file(path: str) -> str:
    """Прочитать текстовый файл из sandbox. Бинарники режутся."""
    def _do() -> str:
        target = resolve_in_sandbox(path)
        if not target.exists():
            return f"[read_file] '{path}' не существует"
        if not target.is_file():
            return f"[read_file] '{path}' не файл"
        data = target.read_bytes()
        truncated = len(data) > MAX_READ_BYTES
        snippet = data[:MAX_READ_BYTES]
        try:
            text = snippet.decode("utf-8")
        except UnicodeDecodeError:
            return f"[read_file] '{path}' выглядит как бинарник, пропускаю"
        if truncated:
            text += f"\n\n[... обрезано, файл {len(data)} байт, показано {MAX_READ_BYTES}]"
        return text
    return await asyncio.to_thread(_do)


async def write_file(path: str, content: str) -> str:
    """Записать (перезаписать) текстовый файл в sandbox."""
    def _do() -> str:
        target = resolve_in_sandbox(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        return f"[write_file] OK, записано {len(content)} символов в {target.relative_to(sandbox_root())}"
    return await asyncio.to_thread(_do)


async def list_dir(path: str = ".") -> str:
    """Листинг папки в sandbox."""
    def _do() -> str:
        target = resolve_in_sandbox(path)
        if not target.exists():
            return f"[list_dir] '{path}' не существует"
        if not target.is_dir():
            return f"[list_dir] '{path}' не директория"
        entries: list[str] = []
        for i, p in enumerate(sorted(target.iterdir())):
            if i >= MAX_LIST_ENTRIES:
                entries.append(f"... (обрезано на {MAX_LIST_ENTRIES})")
                break
            tag = "DIR " if p.is_dir() else "FILE"
            try:
                size = p.stat().st_size if p.is_file() else 0
            except OSError:
                size = 0
            entries.append(f"{tag} {size:>10}  {p.name}")
        if not entries:
            return f"[list_dir] '{path}' пустая"
        return "\n".join(entries)
    return await asyncio.to_thread(_do)


async def search_files(pattern: str, path: str = ".") -> str:
    """Поиск pattern (regex) по содержимому файлов внутри sandbox-папки."""
    def _do() -> str:
        target = resolve_in_sandbox(path)
        if not target.exists() or not target.is_dir():
            return f"[search_files] '{path}' не директория"
        try:
            rx = re.compile(pattern, re.IGNORECASE)
        except re.error as e:
            return f"[search_files] невалидный regex: {e}"
        hits: list[str] = []
        for fp in target.rglob("*"):
            if not fp.is_file():
                continue
            try:
                txt = fp.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            for ln_no, ln in enumerate(txt.splitlines(), 1):
                if rx.search(ln):
                    rel = fp.relative_to(sandbox_root())
                    hits.append(f"{rel}:{ln_no}: {ln.strip()[:200]}")
                    if len(hits) >= 50:
                        hits.append("... (обрезано на 50 совпадений)")
                        return "\n".join(hits)
        return "\n".join(hits) if hits else "[search_files] ничего не найдено"
    return await asyncio.to_thread(_do)
