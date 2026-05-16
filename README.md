# Home AI Assistant

- bot/      — код Telegram-бота (aiogram + Ollama client)
- data/     — conversation history, whitelist (JSON), user profiles
- logs/     — логи бота
- scripts/  — служебные скрипты (backup, restart, smoke test)

## Ollama
- runtime: systemd unit `ollama` (sudo systemctl status ollama)
- API: http://localhost:11434
- модели: `ollama list`
- основная: qwen2.5:7b-instruct-q4_K_M
- установлены все 5 моделей (согласовано 2026-05-15):
  - qwen2.5:7b-instruct-q4_K_M
  - qwen2.5-coder:7b
  - qwen2.5vl:7b
  - nomic-embed-text
  - gemma4:e2b

## Bootstrap
Сгенерировано 2026-05-15T20:09:54+03:00 скриптом setup-ai-server-p0.sh.
