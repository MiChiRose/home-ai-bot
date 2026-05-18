"""Voice-to-text через faster-whisper (offline, CUDA).

Используется в bot.py при получении F.voice — скачиваем oga, конвертируем ffmpeg в wav,
транскрибируем, возвращаем текст.
"""
from __future__ import annotations
import asyncio
import os
from pathlib import Path

# Глобальная модель — ленивая инициализация (грузим один раз при первом transcribe)
_STT_MODEL = None
_STT_LOCK = asyncio.Lock()


async def _get_model():
    """Lazy load Whisper. Subsequent calls дают cached instance."""
    global _STT_MODEL
    if _STT_MODEL is not None:
        return _STT_MODEL
    async with _STT_LOCK:
        if _STT_MODEL is not None:
            return _STT_MODEL

        def _load():
            from faster_whisper import WhisperModel
            model_size = os.environ.get("STT_MODEL", "medium")
            compute_type = os.environ.get("STT_COMPUTE_TYPE", "int8_float16")
            device = os.environ.get("STT_DEVICE", "cuda")
            return WhisperModel(model_size, device=device, compute_type=compute_type)

        _STT_MODEL = await asyncio.to_thread(_load)
        return _STT_MODEL


async def _convert_oga_to_wav(src_path: Path, dst_path: Path) -> bool:
    """ffmpeg -i src.oga -ac 1 -ar 16000 dst.wav."""
    proc = await asyncio.create_subprocess_exec(
        "ffmpeg", "-y", "-i", str(src_path),
        "-ac", "1", "-ar", "16000",
        str(dst_path),
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.DEVNULL,
    )
    rc = await proc.wait()
    return rc == 0 and dst_path.exists()


async def transcribe_voice(oga_path: str) -> tuple[bool, str]:
    """Транскрибирует voice-файл. Возвращает (success, text_or_error)."""
    p = Path(oga_path)
    if not p.is_file():
        return False, f"voice file not found: {oga_path}"

    # Конвертация в wav (faster-whisper тоже может opus, но надёжнее wav)
    wav = p.with_suffix(".wav")
    if not await _convert_oga_to_wav(p, wav):
        return False, "ffmpeg conversion failed"

    try:
        model = await _get_model()
    except Exception as e:
        return False, f"STT model load failed: {type(e).__name__}: {e}"

    def _transcribe():
        lang = os.environ.get("STT_LANGUAGE", "ru")
        segments, info = model.transcribe(
            str(wav),
            language=lang,
            beam_size=5,
            vad_filter=True,  # отрезает silence
        )
        text = " ".join(s.text.strip() for s in segments).strip()
        return text

    try:
        text = await asyncio.to_thread(_transcribe)
        # Cleanup
        try:
            wav.unlink()
        except Exception:
            pass
        if not text:
            return False, "(пустая транскрипция — возможно тишина или шум)"
        return True, text
    except Exception as e:
        return False, f"transcribe error: {type(e).__name__}: {e}"
