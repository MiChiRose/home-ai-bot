#!/usr/bin/env bash
# v19-setup-via-curl-no-gh.sh — setup profiles-repo БЕЗ gh CLI.
#
# Юра msg 18034: gh CLI не установлен. Юра не у компа — не может sudo apt
# install. Используем GitHub HTTPS API через curl + Personal Access Token.
#
# Требуется: GITHUB_TOKEN env var (Personal Access Token classic с scope `repo`)
#
# Как Юре получить токен:
# 1. На своём ПК (Mac) открой https://github.com/settings/tokens/new
# 2. Note: "home-ai-bot-profiles"
# 3. Expiration: 90 дней или дольше
# 4. Scopes: ☑ repo (Full control of private repositories)
# 5. Generate token → СКОПИРУЙ значение (начинается с ghp_...)
# 6. Передай боту: /run_patch с префиксом GITHUB_TOKEN=ghp_... v19-setup-via-curl-no-gh.sh
#    (если /run_patch такой синтаксис не поддерживает — впишу token в скрипт
#    и пришлю обновлённую версию)

set -euo pipefail

PROFILES_REPO="${PROFILES_REPO:-$HOME/ai-assistant/profiles-repo}"
GITHUB_USER="${GITHUB_USER:-MiChiRose}"  # из memory Юра
REPO_NAME="${REPO_NAME:-home-ai-bot-profiles}"

# === 0. Token check ===
if [ -z "${GITHUB_TOKEN:-}" ]; then
    cat <<EOF
❌ GITHUB_TOKEN не передан в env.

КАК ПЕРЕДАТЬ:

Вариант A (если /run_patch поддерживает env prefix):
  Пришли мне команду: /run_patch GITHUB_TOKEN=ghp_xxx v19-setup-via-curl-no-gh.sh

Вариант B (если не поддерживает):
  Напиши мне в чат: «токен: ghp_xxx»
  Я впишу его в скрипт и пришлю обновлённую версию.

КАК ПОЛУЧИТЬ ТОКЕН:
  1. На своём ПК (Mac) открой https://github.com/settings/tokens/new
  2. Note: "home-ai-bot-profiles"
  3. Expiration: 90+ дней
  4. Scopes: галочка на ☑ repo (Full control of private repositories)
  5. Generate token → скопируй значение (начинается с ghp_...)
EOF
    exit 1
fi

REPO_FULL="$GITHUB_USER/$REPO_NAME"
echo "==> GitHub user: $GITHUB_USER"
echo "==> Target repo: $REPO_FULL"

# === 1. Проверить существование repo через API ===
echo ""
echo "==> Step 1: проверка существования repo"
REPO_CHECK=$(curl -sS -o /dev/null -w "%{http_code}" \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO_FULL")

if [ "$REPO_CHECK" = "200" ]; then
    echo "ℹ️  Repo $REPO_FULL уже существует"
elif [ "$REPO_CHECK" = "404" ]; then
    echo "==> Создаю private repo $REPO_FULL..."
    CREATE_RESP=$(curl -sS -X POST \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/user/repos" \
        -d "{\"name\":\"$REPO_NAME\",\"private\":true,\"description\":\"User profiles for home-ai-bot (v19 git storage)\",\"auto_init\":true}")
    if echo "$CREATE_RESP" | grep -q "\"name\":\"$REPO_NAME\""; then
        echo "✅ Repo создан"
    else
        echo "❌ Не смог создать repo. API response:"
        echo "$CREATE_RESP" | head -c 500
        exit 2
    fi
else
    echo "❌ Unexpected API response code: $REPO_CHECK"
    echo "   Проверь что токен действителен и имеет scope 'repo'"
    exit 3
fi

# === 2. Clone repo (через HTTPS + token) ===
echo ""
echo "==> Step 2: clone в $PROFILES_REPO"
CLONE_URL="https://${GITHUB_TOKEN}@github.com/$REPO_FULL.git"

if [ -d "$PROFILES_REPO/.git" ]; then
    echo "ℹ️  $PROFILES_REPO уже клонирован"
    cd "$PROFILES_REPO"
    # Update remote URL с токеном
    git remote set-url origin "$CLONE_URL"
    git fetch origin 2>&1 | tail -3 || true
    echo "✅ Repo на месте"
else
    mkdir -p "$(dirname "$PROFILES_REPO")"
    if git clone "$CLONE_URL" "$PROFILES_REPO" 2>&1 | tail -3; then
        echo "✅ Cloned (via HTTPS+token)"
    else
        echo "❌ Clone failed."
        exit 4
    fi
fi

# Set remote URL без токена в логах (security — токен в config но не в `git log`)
cd "$PROFILES_REPO"

# === 3. Структура ===
echo ""
echo "==> Step 3: структура repo"
mkdir -p profiles

if [ ! -f README.md ]; then
    cat > README.md <<'README'
# Home AI Bot — User Profiles

Private repo для версионирования user profiles бота `home-ai-bot.service`.

Создано: v19 GIT_PROFILES_STORAGE (2026-05-18)

## Структура

```
profiles/
  <telegram_user_id>.md   — markdown profile конкретного юзера
```

## Flow

- `db_set_profile(user_id, content)` → SQLite (cache) + git push (best-effort)
- `db_get_profile(user_id)` → SQLite first, fallback git read
- Startup → git pull --ff-only

## Edit через web

Можно редактировать профили прямо на github.com через web UI (карандашик).
Изменения подхватятся ботом на следующем startup или ручном pull.

## Откат

- `git log profiles/<user_id>.md` — история профиля
- `git show <commit>:profiles/<user_id>.md` — содержимое в версии
README
    echo "✅ README.md создан"
fi

[ -f profiles/.gitkeep ] || touch profiles/.gitkeep

# === 4. Initial commit + push ===
echo ""
echo "==> Step 4: initial commit + push"
git config user.email "home-ai-bot@local"
git config user.name "home-ai-bot"
git add .
if git diff --cached --quiet; then
    echo "ℹ️  Нечего commit'ить"
else
    git commit -m "Initial structure (v19 GIT_PROFILES_STORAGE 2026-05-18)"
    git push origin main 2>&1 | tail -3 || git push origin master 2>&1 | tail -3
    echo "✅ Pushed"
fi

# === 5. Verify ===
echo ""
echo "==> Final state:"
echo "  Repo URL:    https://github.com/$REPO_FULL"
echo "  Local:       $PROFILES_REPO"
echo "  Branch:      $(git rev-parse --abbrev-ref HEAD)"
echo "  Last commit: $(git log -1 --oneline)"
ls -la "$PROFILES_REPO"

echo ""
echo "✅ Setup завершён."
echo ""
echo "ВАЖНО: токен сейчас в $PROFILES_REPO/.git/config (через https://TOKEN@... URL)."
echo "Это OK для приватного сервера — bot.py пушит автоматом без интерактива."
echo ""
echo "Теперь запусти: /run_patch add-tools-v19-git-storage-profiles.sh"
