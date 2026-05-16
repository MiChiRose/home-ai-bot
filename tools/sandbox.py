"""Path resolver для file ops. Не позволяет модели вылезти из BOT_SANDBOX."""
from __future__ import annotations
import os
from pathlib import Path


def sandbox_root() -> Path:
    root = Path(os.environ.get("BOT_SANDBOX", str(Path.home() / "bot-workspace"))).expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    return root


def resolve_in_sandbox(user_path: str) -> Path:
    """Резолвит user-supplied путь и подтверждает, что он внутри песочницы.
    Кидает PermissionError если путь escape'ит наружу (через .. или абсолютный путь вне sandbox).
    """
    root = sandbox_root()
    raw = Path(user_path)
    target = (raw if raw.is_absolute() else (root / raw)).resolve()
    try:
        target.relative_to(root)
    except ValueError as e:
        raise PermissionError(f"Path '{user_path}' escapes sandbox {root}") from e
    return target
