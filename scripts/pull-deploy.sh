#!/usr/bin/env bash
# pull-deploy.sh — safe auto-pull + deploy. Запускается через systemd-timer.

set -u
ROOT="${BOT_REPO_DIR:-$HOME/ai-assistant}"
UNIT="${BOT_SYSTEMD_UNIT:-home-ai-bot.service}"
LOG="$ROOT/data/auto-pull.log"
VENV_PY="$ROOT/.venv/bin/python"
VENV_PIP="$ROOT/.venv/bin/pip"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG"
}

cd "$ROOT" || { log "FATAL: cd $ROOT упал"; exit 1; }

# 1. Fetch
if ! git fetch origin main 2>/dev/null; then
    log "git fetch упал — нет сети или auth issues"
    exit 0
fi

LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)

if [[ "$LOCAL" == "$REMOTE" ]]; then
    # Тишина — нет изменений
    exit 0
fi

log "Обновления есть: $LOCAL → $REMOTE"

# 2. Stash локальные изменения (если есть случайные правки)
DIRTY=$(git status --porcelain | wc -l)
if (( DIRTY > 0 )); then
    log "Локальных изменений: $DIRTY, stash"
    git stash --include-untracked -m "auto-pull-stash-$(date +%s)" >/dev/null 2>&1 || true
fi

# 3. Запомнить старый HEAD для rollback
PREV_HEAD="$LOCAL"

# 4. Проверить изменился ли requirements.txt
REQ_CHANGED=$(git diff --name-only "$LOCAL" "$REMOTE" | grep -c '^requirements.txt$' || true)

# 5. Pull
if ! pull_out="$(git pull --ff-only origin main 2>&1)"; then
    log "git pull --ff-only упал: $pull_out"
    exit 1
fi
log "Pull OK"

# 6. Обновить deps если изменился requirements.txt
if (( REQ_CHANGED > 0 )) && [[ -x "$VENV_PIP" ]]; then
    log "requirements.txt изменился — pip install"
    "$VENV_PIP" install -r requirements.txt >> "$LOG" 2>&1 || log "pip install warning (non-fatal)"
fi

# 7. Syntax check всего Python кода
SYNTAX_OK=true
for py in $(find "$ROOT" -maxdepth 4 -name '*.py' -not -path '*/.venv/*' -not -path '*/__pycache__/*' -not -path '*/backups/*' -not -path '*/updates/*'); do
    if ! "$VENV_PY" -m py_compile "$py" 2>>"$LOG"; then
        log "SYNTAX ERROR в $py"
        SYNTAX_OK=false
    fi
done

if ! $SYNTAX_OK; then
    log "Syntax check FAIL — rollback к $PREV_HEAD"
    git reset --hard "$PREV_HEAD" >> "$LOG" 2>&1
    log "Rollback done. Сервис НЕ рестартовался."
    exit 1
fi

# 8. Restart сервиса
log "Syntax OK. Restart $UNIT"
if systemctl --user restart "$UNIT" 2>>"$LOG"; then
    sleep 2
    if systemctl --user is-active --quiet "$UNIT"; then
        log "✓ Deploy успешен: $(git log --oneline -1)"
    else
        log "✗ Сервис не активен после restart — проверь journalctl"
        # НЕ откатываем — issue может быть в env/runtime, не в коде
    fi
else
    log "systemctl restart упал — нет user-DBus session?"
fi
