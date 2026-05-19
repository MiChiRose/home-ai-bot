#!/bin/bash

# Файл, куда сохраним все результаты
OUTPUT="diag_results.txt"

echo "=== DIAGNOSTIC REPORT ($(date)) ===" > $OUTPUT
echo "" >> $OUTPUT

echo "--- Directory Structure ---" >> $OUTPUT
ls -R >> $OUTPUT
echo "" >> $OUTPUT

echo "--- Environment Variables (Ollama/Model related) ---" >> $OUTPUT
env | grep -E "OLLAMA|MODEL|URL|PORT" | grep -v "TOKEN" >> $OUTPUT
echo "" >> $OUTPUT

echo "--- Ollama Status ---" >> $OUTPUT
if command -v ollama &> /dev/null
then
    ollama list >> $OUTPUT
    echo "--- Active Models ---" >> $OUTPUT
    ollama ps >> $OUTPUT
else
    echo "ollama command not found" >> $OUTPUT
fi
echo "" >> $OUTPUT

echo "--- Python Packages (httpx, ollama, aiogram) ---" >> $OUTPUT
pip list | grep -E "httpx|ollama|aiogram|dotenv" >> $OUTPUT
echo "" >> $OUTPUT

echo "--- .env File (without secrets) ---" >> $OUTPUT
if [ -f .env ]; then
    grep -vE "TOKEN|KEY|PASSWORD|SECRET" .env >> $OUTPUT
else
    echo ".env file not found" >> $OUTPUT
fi
echo "" >> $OUTPUT

echo "--- Last 50 lines of log.txt ---" >> $OUTPUT
if [ -f log.txt ]; then
    tail -n 50 log.txt >> $OUTPUT
else
    echo "log.txt not found" >> $OUTPUT
fi
echo "" >> $OUTPUT

echo "--- End of Report ---" >> $OUTPUT

# Если бот настроен так, что он просто запускает скрипт, 
# то вывод в stdout тоже может пригодиться.
cat $OUTPUT
