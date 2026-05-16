"""Image generation tool через ComfyUI HTTP API + SD3 medium."""
from __future__ import annotations
import asyncio
import json
import os
import time
import uuid
from pathlib import Path

import httpx

from .sandbox import sandbox_root

COMFY_URL = os.environ.get("COMFY_URL", "http://127.0.0.1:8188").rstrip("/")
DEFAULT_STEPS = int(os.environ.get("SD3_STEPS", "28"))
DEFAULT_CFG = float(os.environ.get("SD3_CFG", "4.5"))
TIMEOUT_SECONDS = int(os.environ.get("SD3_TIMEOUT", "180"))


def _build_workflow(prompt: str, negative: str, width: int, height: int, steps: int, cfg: float, seed: int) -> dict:
    """Минимальный SD3 workflow для ComfyUI."""
    return {
        "3": {  # KSampler
            "class_type": "KSampler",
            "inputs": {
                "seed": seed,
                "steps": steps,
                "cfg": cfg,
                "sampler_name": "dpmpp_2m",
                "scheduler": "sgm_uniform",
                "denoise": 1.0,
                "model": ["4", 0],
                "positive": ["6", 0],
                "negative": ["7", 0],
                "latent_image": ["5", 0],
            },
        },
        "4": {  # CheckpointLoaderSimple
            "class_type": "CheckpointLoaderSimple",
            "inputs": {"ckpt_name": "sd3_medium_incl_clips_t5xxlfp8.safetensors"},
        },
        "5": {  # EmptyLatentImage
            "class_type": "EmptyLatentImage",
            "inputs": {"width": width, "height": height, "batch_size": 1},
        },
        "6": {  # Positive CLIPTextEncode
            "class_type": "CLIPTextEncode",
            "inputs": {"text": prompt, "clip": ["4", 1]},
        },
        "7": {  # Negative CLIPTextEncode
            "class_type": "CLIPTextEncode",
            "inputs": {"text": negative, "clip": ["4", 1]},
        },
        "8": {  # VAEDecode
            "class_type": "VAEDecode",
            "inputs": {"samples": ["3", 0], "vae": ["4", 2]},
        },
        "9": {  # SaveImage
            "class_type": "SaveImage",
            "inputs": {"images": ["8", 0], "filename_prefix": "tg_bot_gen"},
        },
    }


async def generate_image(
    prompt: str,
    negative_prompt: str = "low quality, blurry, distorted, deformed, watermark",
    width: int = 1024,
    height: int = 1024,
    seed: int | None = None,
) -> str:
    """Генерирует картинку через ComfyUI и сохраняет в sandbox/output/.
    Возвращает путь к файлу (для модели — она потом скажет «готово, output/X.png»),
    bot.py отправит её юзеру."""
    if not prompt or not prompt.strip():
        return "[generate_image ERROR] пустой prompt"

    # Bound dimensions
    width = max(512, min(int(width), 1536))
    height = max(512, min(int(height), 1536))
    seed = int(seed) if seed is not None else int(time.time() * 1000) % 2_000_000_000

    workflow = _build_workflow(prompt.strip(), negative_prompt.strip(), width, height, DEFAULT_STEPS, DEFAULT_CFG, seed)
    client_id = uuid.uuid4().hex

    async with httpx.AsyncClient(timeout=TIMEOUT_SECONDS) as client:
        # 1. Запускаем prompt
        try:
            r = await client.post(f"{COMFY_URL}/prompt", json={"prompt": workflow, "client_id": client_id})
            r.raise_for_status()
            prompt_id = r.json()["prompt_id"]
        except httpx.HTTPError as e:
            return f"[generate_image ERROR] ComfyUI не отвечает: {e}"
        except KeyError:
            return "[generate_image ERROR] ComfyUI не вернул prompt_id"

        # 2. Опрос history до готовности
        deadline = time.time() + TIMEOUT_SECONDS
        while time.time() < deadline:
            await asyncio.sleep(2)
            try:
                hr = await client.get(f"{COMFY_URL}/history/{prompt_id}")
                hist = hr.json()
            except Exception:
                continue
            entry = hist.get(prompt_id)
            if not entry:
                continue
            outputs = entry.get("outputs", {})
            for node_id, node_out in outputs.items():
                images = node_out.get("images", [])
                if images:
                    img_info = images[0]
                    # 3. Скачиваем готовый файл
                    params = {"filename": img_info["filename"], "subfolder": img_info.get("subfolder", ""), "type": img_info.get("type", "output")}
                    try:
                        ir = await client.get(f"{COMFY_URL}/view", params=params)
                        ir.raise_for_status()
                    except httpx.HTTPError as e:
                        return f"[generate_image ERROR] не смог скачать готовое изображение: {e}"
                    # 4. Сохраняем в sandbox/output/
                    out_dir = sandbox_root() / "output"
                    out_dir.mkdir(parents=True, exist_ok=True)
                    out_path = out_dir / f"img_{int(time.time())}_{seed}.png"
                    out_path.write_bytes(ir.content)
                    return f"[generate_image] OK. Файл: output/{out_path.name} (seed={seed}, {width}x{height}). bot.py отправит его в чат автоматически."

        return f"[generate_image ERROR] таймаут {TIMEOUT_SECONDS}s — ComfyUI не завершил генерацию"
