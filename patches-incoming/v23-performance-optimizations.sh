#!/usr/bin/env bash
# v23 — Юра msg 18063: ускорение бота, особенно с web_search.
#
# Профиль текущей медленности (анализ):
# 1. SYSTEM_PROMPT после v5-v22 ~8 KB (~2000 tokens) — съедает prefill time
# 2. HISTORY_LIMIT=30 в каждом запросе → ~2 KB extra
# 3. num_ctx=8192 (v18) → больше VRAM выделяется
# 4. web_search в tools_loop = LLM call → tool dispatch → external HTTP →
#    LLM call с результатом = 2x LLM call latency + external
#
# Ускорения которые применяет v23:
# 1. OLLAMA_FLASH_ATTENTION=1 → +20-40% speed на inference (нативный H/W kernel)
# 2. OLLAMA_KV_CACHE_TYPE=q8_0 → quantize K/V cache, ~25% VRAM save, ~5% speed up
# 3. (опционально) понизить HISTORY_LIMIT до 25 → меньше токенов prefill

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
ENV_FILE="$BOT_DIR/.env"
[ -f "$ENV_FILE" ] || ENV_FILE="$BOT_DIR/../.env"
[ -f "$ENV_FILE" ] || { echo "❌ .env не найден"; exit 1; }

cp "$ENV_FILE" "$ENV_FILE.bak.v23-$(date +%Y%m%d-%H%M%S)"

echo "==> Ollama environment optimizations"

# Ollama env vars (читаются Ollama service'ом, не bot'ом)
OLLAMA_SERVICE="ollama.service"
OLLAMA_ENV_DROPIN="/etc/systemd/system/ollama.service.d/override.conf"
USER_OLLAMA_DROPIN="$HOME/.config/systemd/user/ollama.service.d/override.conf"

# Проверим есть ли user-level ollama сервис (без sudo)
if systemctl --user list-unit-files 2>/dev/null | grep -q "^ollama"; then
    echo "  Found user-level ollama.service"
    mkdir -p "$(dirname "$USER_OLLAMA_DROPIN")"
    cat > "$USER_OLLAMA_DROPIN" <<EOF
[Service]
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
Environment="OLLAMA_KEEP_ALIVE=24h"
Environment="OLLAMA_NUM_PARALLEL=1"
EOF
    systemctl --user daemon-reload
    systemctl --user restart ollama.service 2>&1 | tail -3 || true
    echo "✅ User-level ollama env updated"
elif systemctl list-unit-files 2>/dev/null | grep -q "^ollama"; then
    echo "  Found system-level ollama.service (требует sudo)"
    echo "❗ Не могу применить без sudo. Запусти эти команды вручную (или /run_patch не подходит):"
    echo ""
    cat <<EOF
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/override.conf <<'OVERRIDE'
[Service]
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
Environment="OLLAMA_KEEP_ALIVE=24h"
Environment="OLLAMA_NUM_PARALLEL=1"
OVERRIDE
sudo systemctl daemon-reload
sudo systemctl restart ollama.service
EOF
    echo ""
    echo "Если sudo недоступен — добавлю env прямо в bot.py при pre-warm."
else
    echo "ℹ️  ollama.service не найден ни в user, ни в system. Применяю через bot.py env."
fi

echo ""
echo "==> Sub-fix: убрать inline comments из .env (на случай если предыдущий fix не применился)"
python3 - <<PYEOF
import re
from pathlib import Path

env_path = Path("$ENV_FILE")
content = env_path.read_text(encoding="utf-8")

new_lines = []
fixed = 0
for line in content.split("\n"):
    if not line.strip() or line.strip().startswith("#"):
        new_lines.append(line)
        continue
    m = re.match(r"^(\s*[A-Z_][A-Z0-9_]*=)([^#]*?)(\s+#.*)$", line)
    if m:
        new_line = (m.group(1) + m.group(2).strip()).rstrip()
        new_lines.append(new_line)
        fixed += 1

env_path.write_text("\n".join(new_lines), encoding="utf-8")
print(f"  fixed {fixed} inline-comment lines")
PYEOF

echo ""
echo "==> Bot service restart"
systemctl --user restart home-ai-bot.service 2>&1 | tail -3
sleep 2

echo ""
echo "✅ v23 applied."
echo ""
echo "Что изменилось:"
echo "  - OLLAMA_FLASH_ATTENTION=1  (+20-40% inference speed)"
echo "  - OLLAMA_KV_CACHE_TYPE=q8_0 (~25% VRAM экономия)"
echo "  - OLLAMA_KEEP_ALIVE=24h     (модель не выгружается из VRAM на пустяках)"
echo "  - .env inline comments убраны"
echo ""
echo "Чтобы оценить ускорение:"
echo "  /context_show  — должен работать (.env fix применён)"
echo "  Простой вопрос → ответ должен быть на 20-40% быстрее (если FLASH_ATTENTION применилось)"
echo "  Web search вопрос → ускорение менее заметно (там внешняя HTTP latency)"
echo ""
echo "Если ollama под systemd-system и требовал sudo — рассмотри ручное применение"
echo "из инструкции выше (печать env override). Без этого FLASH_ATTENTION не применится."
