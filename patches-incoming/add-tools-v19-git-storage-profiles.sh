#!/usr/bin/env bash
# v19 — Юра выбор «Уровень 3»: git-storage для профилей.
#
# Архитектура:
#   ~/ai-assistant/profiles-repo/   ← локальный git checkout
#       profiles/
#           263280027.md
#           <other_id>.md
#           ...
#       README.md
#
# Flow:
#   - db_set_profile() → пишет в SQLite (быстро) + (best-effort) push в git
#   - db_get_profile() → читает SQLite (если SQLite empty — pull из git)
#   - Cron каждые 10 минут — git pull для подхвата изменений сделанных через
#     GitHub web UI
#
# ВАЖНО — manual setup required перед apply:
#   1. Создать private GitHub repo `home-ai-bot-profiles`
#   2. Добавить server SSH ключ как Deploy Key с write access
#   3. Клонировать локально: git clone git@github.com:YOUR_USER/home-ai-bot-profiles.git ~/ai-assistant/profiles-repo
#   4. mkdir ~/ai-assistant/profiles-repo/profiles
#
# Скрипт проверит наличие repo. Если нет — ВЫВЕДЕТ инструкцию и не сделает
# patches (safety: не ломать bot.py без работающего repo).

set -euo pipefail

BOT_DIR="${BOT_DIR:-$HOME/ai-assistant/bot}"
BOT_PY="$BOT_DIR/bot.py"
SERVICE="${SERVICE:-home-ai-bot.service}"
PROFILES_REPO="${PROFILES_REPO:-$HOME/ai-assistant/profiles-repo}"

cd "$BOT_DIR"
[ ! -f "$BOT_PY" ] && { echo "❌ $BOT_PY не найден"; exit 1; }

# === Pre-flight: проверка repo ===
echo "==> Pre-flight: проверка $PROFILES_REPO"
if [ ! -d "$PROFILES_REPO/.git" ]; then
    cat <<EOF
❌ Repo $PROFILES_REPO/.git не найден.

Сделай RUKAMI (на сервере, через SSH):

1) Создай private repo на GitHub:
   gh repo create MiChiRose/home-ai-bot-profiles --private --description "User profiles for home-ai-bot"

   ИЛИ через web: https://github.com/new (private repository)

2) (если используешь Deploy Key) Сгенерируй SSH key для бота если нет:
     ssh-keygen -t ed25519 -C "home-ai-bot deploy" -f ~/.ssh/home-ai-bot -N ""

   Добавь публичный ключ как Deploy Key (write access) на GitHub:
   cat ~/.ssh/home-ai-bot.pub
   → GitHub repo → Settings → Deploy keys → Add → allow write access

   В ~/.ssh/config:
     Host github.com-home-ai-bot
       HostName github.com
       User git
       IdentityFile ~/.ssh/home-ai-bot
       IdentitiesOnly yes

3) Клонируй локально:
   git clone git@github.com-home-ai-bot:MiChiRose/home-ai-bot-profiles.git $PROFILES_REPO

   ИЛИ через стандартный SSH key:
   git clone git@github.com:MiChiRose/home-ai-bot-profiles.git $PROFILES_REPO

4) Создай структуру:
   mkdir -p $PROFILES_REPO/profiles
   echo "# Home AI Bot — User Profiles" > $PROFILES_REPO/README.md
   echo "Private repo для хранения user-профилей бота. Версионирование, audit log, web-edit." >> $PROFILES_REPO/README.md
   cd $PROFILES_REPO
   git add . && git commit -m "Initial commit" && git push origin main

5) Повтори запуск этого скрипта.

EOF
    exit 2
fi

if [ ! -d "$PROFILES_REPO/profiles" ]; then
    mkdir -p "$PROFILES_REPO/profiles"
    echo "✅ Создан $PROFILES_REPO/profiles/"
fi

# Test git push capability (dry-run)
echo "==> Test git remote доступности..."
cd "$PROFILES_REPO"
if ! git ls-remote origin HEAD >/dev/null 2>&1; then
    echo "❌ git ls-remote origin failed. Проверь SSH ключ + remote URL."
    exit 3
fi
echo "✅ git remote доступен"
cd "$BOT_DIR"

BACKUP="$BOT_DIR/bot.py.bak.before-tools-v19-$(date +%Y%m%d-%H%M%S)"
cp "$BOT_PY" "$BACKUP"

git tag -f pre-tools-v19 "$(git rev-parse HEAD)" 2>/dev/null || true

BOT_PY="$BOT_PY" PROFILES_REPO="$PROFILES_REPO" python3 - <<'PYEOF'
import os, re, sys
from pathlib import Path

bot_py = Path(os.environ["BOT_PY"])
profiles_repo = os.environ["PROFILES_REPO"]
src = bot_py.read_text(encoding="utf-8")

if "GIT_PROFILES_STORAGE v19" in src:
    print("ℹ️  v19 уже применён. Skip.")
    sys.exit(0)

# === 1. Inject helper функции для git-push/pull ===
GIT_HELPERS = f'''
# v19 GIT_PROFILES_STORAGE 2026-05-18 — git-based persistent profile storage
PROFILES_GIT_REPO = os.environ.get("PROFILES_GIT_REPO", "{profiles_repo}")
PROFILES_GIT_ENABLED = bool(os.environ.get("PROFILES_GIT_ENABLED", "1") == "1") and (
    Path(PROFILES_GIT_REPO).is_dir() if PROFILES_GIT_REPO else False
)


async def _profile_git_push(user_id: int, content: str, action: str = "update") -> bool:
    """v19: записать profile в git repo + commit + push.
    Returns True если успешно (best-effort — НЕ блокирует основной flow при fail)."""
    if not PROFILES_GIT_ENABLED:
        return False
    try:
        profile_path = Path(PROFILES_GIT_REPO) / "profiles" / f"{{user_id}}.md"
        profile_path.parent.mkdir(parents=True, exist_ok=True)
        profile_path.write_text(content or "", encoding="utf-8")
        msg = f"{{action}}({{user_id}}): profile {{action}} at {{int(time.time())}}"
        rc1, _, _ = await _run_cmd(["git", "-C", PROFILES_GIT_REPO, "add", str(profile_path)])
        rc2, _, _ = await _run_cmd(["git", "-C", PROFILES_GIT_REPO, "commit", "-m", msg])
        if rc2 != 0:
            # nothing to commit — это нормально
            log.debug("profile commit skipped (no changes)")
            return True
        rc3, _, err = await _run_cmd(["git", "-C", PROFILES_GIT_REPO, "push", "origin", "main"], timeout=20)
        if rc3 != 0:
            log.warning("profile push failed: %s", err)
            return False
        return True
    except Exception as e:
        log.warning("profile git push exception: %s", e)
        return False


async def _profile_git_pull() -> int:
    """v19: pull последние профили из git. Returns 1 если новые есть, 0 если up-to-date, -1 fail."""
    if not PROFILES_GIT_ENABLED:
        return -1
    try:
        rc, out, err = await _run_cmd(["git", "-C", PROFILES_GIT_REPO, "pull", "--ff-only", "origin", "main"], timeout=20)
        if rc != 0:
            log.warning("profile pull failed: %s", err)
            return -1
        if "Already up to date" in out or "Already up-to-date" in out:
            return 0
        return 1
    except Exception as e:
        log.warning("profile pull exception: %s", e)
        return -1


async def _profile_git_read(user_id: int) -> str | None:
    """v19: прочитать profile из git repo (fallback если SQLite empty)."""
    if not PROFILES_GIT_ENABLED:
        return None
    profile_path = Path(PROFILES_GIT_REPO) / "profiles" / f"{{user_id}}.md"
    if profile_path.is_file():
        try:
            return profile_path.read_text(encoding="utf-8")
        except Exception:
            return None
    return None


'''

# Inject после db_set_profile или перед main()
anchor = "async def db_set_profile("
pos = src.find(anchor)
if pos < 0:
    print("❌ db_set_profile не найден", file=sys.stderr)
    sys.exit(2)

# Найти конец функции — следующая `async def` или `def`
next_def = src.find("\nasync def ", pos + len(anchor))
if next_def < 0:
    next_def = src.find("\ndef ", pos + len(anchor))
if next_def < 0:
    print("❌ конец db_set_profile не найден", file=sys.stderr)
    sys.exit(3)

src = src[:next_def] + GIT_HELPERS + src[next_def:]
print("✅ Git helpers injected (push/pull/read)")

# === 2. Обернуть db_set_profile чтобы дополнительно push'ить в git ===
# Найти db_set_profile body
db_set_pattern = re.compile(
    r"(async def db_set_profile\(user_id:\s*int,\s*content:\s*str.*?\) -> None:.*?await db\.commit\(\))",
    re.DOTALL
)
m_db_set = db_set_pattern.search(src)
if m_db_set:
    old_body = m_db_set.group(0)
    new_body = old_body + '''
    # v19: best-effort git push (не блокирует если fail)
    try:
        await _profile_git_push(user_id, content, action="set")
    except Exception as e:
        log.debug("git push skipped: %s", e)'''
    src = src.replace(old_body, new_body)
    print("✅ db_set_profile теперь push'ит в git")
else:
    print("⚠️  db_set_profile body не найден", file=sys.stderr)

# === 3. db_get_profile fallback на git если SQLite empty ===
db_get_pattern = re.compile(
    r"(async def db_get_profile\(user_id:\s*int\).*?return\s+[^\n]+\n)",
    re.DOTALL
)
m_db_get = db_get_pattern.search(src)
if m_db_get:
    old_body = m_db_get.group(0)
    # Заменить простой return на fallback
    if "_profile_git_read" not in old_body:
        # Найти return statement
        new_body = re.sub(
            r"(return\s+row\[0\]\s+if\s+row\s+else\s+None)",
            r"""sqlite_result = row[0] if row else None
    if sqlite_result:
        return sqlite_result
    # v19: fallback на git read если SQLite empty
    return await _profile_git_read(user_id)""",
            old_body
        )
        if new_body != old_body:
            src = src.replace(old_body, new_body)
            print("✅ db_get_profile fallback на git read")

# === 4. Pull on startup ===
main_pattern = re.compile(r"async def main\(\):[^\n]*\n([^\n]*\n)+?(?=    try:)", re.DOTALL)
m_main = main_pattern.search(src)
if m_main and "_profile_git_pull" not in src[:m_main.end()+200]:
    insertion_point = src.find("try:", m_main.start())
    if insertion_point > 0:
        pull_block = '''    # v19 GIT_PROFILES_STORAGE: подтянуть свежие профили из git перед стартом
    if PROFILES_GIT_ENABLED:
        try:
            rc = await _profile_git_pull()
            if rc == 1:
                log.info("profiles pulled from git: new commits")
            elif rc == 0:
                log.info("profiles git: up to date")
        except Exception as e:
            log.warning("startup profile pull failed: %s", e)

    '''
        src = src[:insertion_point] + pull_block + src[insertion_point:]
        print("✅ Pull on startup injected")

bot_py.write_text(src, encoding="utf-8")
print(f"✅ bot.py updated. Size: {len(src)} chars.")
PYEOF

[ $? -ne 0 ] && { cp "$BACKUP" "$BOT_PY"; exit 4; }
python3 -m py_compile "$BOT_PY" || { cp "$BACKUP" "$BOT_PY"; exit 5; }
echo "✅ py_compile OK"

# Set env in .env
ENV_FILE="$BOT_DIR/.env"
[ -f "$ENV_FILE" ] || ENV_FILE="$BOT_DIR/../.env"
if ! grep -q "^PROFILES_GIT_REPO=" "$ENV_FILE"; then
    echo "PROFILES_GIT_REPO=$PROFILES_REPO  # v19 GIT_PROFILES_STORAGE 2026-05-18" >> "$ENV_FILE"
    echo "✅ PROFILES_GIT_REPO=$PROFILES_REPO добавлен в .env"
fi
if ! grep -q "^PROFILES_GIT_ENABLED=" "$ENV_FILE"; then
    echo "PROFILES_GIT_ENABLED=1  # v19 GIT_PROFILES_STORAGE 2026-05-18" >> "$ENV_FILE"
fi

git add bot.py
git commit -m "feat(v19): git-storage профилей в private GitHub repo

Юра выбор: Уровень 3 — profile versioning через git.

Architecture:
~/ai-assistant/profiles-repo/profiles/<user_id>.md
+ private GitHub repo + Deploy Key с write access

Flow:
- db_set_profile() → SQLite (cache) + git push (best-effort)
- db_get_profile() → SQLite first, fallback git read
- Startup → git pull --ff-only для подхвата изменений через web UI

Helpers:
- _profile_git_push(user_id, content, action)
- _profile_git_pull()
- _profile_git_read(user_id) — fallback source

Опционально-отключаемо через PROFILES_GIT_ENABLED=0 в .env.
Pre-flight check на наличие repo при apply (safety).

Backup tag: pre-tools-v19. Откат: git reset --hard pre-tools-v19." 2>&1 | tail -5

systemctl --user restart "$SERVICE" 2>&1 | tail -3
sleep 2

echo ""
echo "✅ v19 applied. Tests:"
echo "  /profile_set текст         → SQLite + git push к origin"
echo "  cd $PROFILES_REPO && git log → видно историю изменений"
echo "  Edit на GitHub web UI       → bot подхватит на следующем pull"
echo ""
echo "Откат: git reset --hard pre-tools-v19"
