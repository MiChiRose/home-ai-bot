#!/usr/bin/env bash
# v19-auto-setup-profiles-repo.sh — автоматическая настройка profiles-repo.
#
# Юра msg 18029: pre-flight v19 fail, нужен manual setup. Но юра физически
# не у компьютера и может только /run_patch. Автоматизирую через `gh`.
#
# Что делает:
# 1. Проверяет `gh auth status` — должно быть установлено и auth'нуто
# 2. Создаёт private repo `home-ai-bot-profiles` через `gh repo create`
#    (если уже существует — skip)
# 3. Использует существующий SSH ключ к GitHub (если работает clone — то OK)
# 4. Клонирует repo в ~/ai-assistant/profiles-repo
# 5. Создаёт начальную структуру (README + profiles/)
# 6. Делает initial commit + push
# 7. После этого можно запускать add-tools-v19-git-storage-profiles.sh

set -euo pipefail

PROFILES_REPO="${PROFILES_REPO:-$HOME/ai-assistant/profiles-repo}"

# === 1. Проверка gh ===
echo "==> Step 1: проверка GitHub CLI"
if ! command -v gh >/dev/null 2>&1; then
    echo "❌ gh CLI не установлен. Установи через: sudo apt install gh"
    echo "   Или используй ручной gh installer: https://cli.github.com"
    exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
    echo "❌ gh не аутентифицирован. Нужно сделать gh auth login (один раз)."
    echo "   ⚠️ это интерактивная команда — нужно браузер. Альтернатива:"
    echo "      1. На своём ПК: gh auth token | cat → скопируй token"
    echo "      2. На сервере: echo TOKEN | gh auth login --with-token"
    echo "      3. Дальше gh auth status должна работать"
    exit 2
fi

GITHUB_USER=$(gh api user --jq .login 2>/dev/null || echo "")
[ -z "$GITHUB_USER" ] && { echo "❌ Не смог определить GitHub username"; exit 3; }
echo "✅ gh auth OK, user=$GITHUB_USER"

REPO_NAME="home-ai-bot-profiles"
REPO_FULL="$GITHUB_USER/$REPO_NAME"

# === 2. Создание repo если нет ===
echo ""
echo "==> Step 2: проверка/создание private repo $REPO_FULL"
if gh repo view "$REPO_FULL" >/dev/null 2>&1; then
    echo "ℹ️  Repo $REPO_FULL уже существует"
else
    if gh repo create "$REPO_FULL" --private \
        --description "User profiles for home-ai-bot (v19 git storage)" \
        --add-readme=false; then
        echo "✅ Repo $REPO_FULL создан"
    else
        echo "❌ Не смог создать repo. Проверь права gh."
        exit 4
    fi
fi

# === 3. Clone если нет ===
echo ""
echo "==> Step 3: clone в $PROFILES_REPO"
if [ -d "$PROFILES_REPO/.git" ]; then
    echo "ℹ️  $PROFILES_REPO уже клонирован"
    cd "$PROFILES_REPO"
    if ! git ls-remote origin HEAD >/dev/null 2>&1; then
        echo "⚠️ remote не работает. Пробую update remote URL..."
        git remote set-url origin "git@github.com:$REPO_FULL.git"
        if ! git ls-remote origin HEAD >/dev/null 2>&1; then
            echo "❌ SSH доступ к $REPO_FULL не работает. Проверь SSH ключи."
            echo "   Тест: ssh -T git@github.com"
            exit 5
        fi
    fi
    echo "✅ Repo на месте, remote работает"
else
    mkdir -p "$(dirname "$PROFILES_REPO")"
    if git clone "git@github.com:$REPO_FULL.git" "$PROFILES_REPO" 2>&1 | tail -3; then
        echo "✅ Cloned"
    else
        echo "❌ SSH clone failed. Возможно нужен Deploy Key."
        echo "   Проверь: ssh -T git@github.com"
        echo "   Если нет SSH: запусти на ПК gh repo clone $REPO_FULL и pushни manualно один файл,"
        echo "   потом перенеси папку на сервер через scp."
        exit 6
    fi
fi

# === 4. Структура ===
echo ""
echo "==> Step 4: структура repo"
cd "$PROFILES_REPO"

mkdir -p profiles

if [ ! -f README.md ]; then
    cat > README.md <<'README'
# Home AI Bot — User Profiles

Private repo для версионирования user profiles бота `home-ai-bot.service`.

## Структура

```
profiles/
  <telegram_user_id>.md   — markdown profile конкретного юзера
```

## Flow

- `db_set_profile(user_id, content)` → SQLite (cache) + git push (best-effort) в этот repo
- `db_get_profile(user_id)` → SQLite first, fallback git read
- Startup → git pull --ff-only для подхвата изменений через web UI

## Edit через web

Прямо на github.com можно редактировать профили через web UI (карандашик).
Изменения подхватятся ботом на следующем startup или ручном pull.

## Откат

Все изменения версионируются через git:
- `git log profiles/<user_id>.md` — история конкретного профиля
- `git show <commit>:profiles/<user_id>.md` — содержимое в определённой версии
- Web blame на github.com — кто и когда менял

Создано: v19 GIT_PROFILES_STORAGE (2026-05-18)
README
    echo "✅ README.md создан"
fi

if [ ! -f profiles/.gitkeep ]; then
    touch profiles/.gitkeep
    echo "✅ profiles/.gitkeep создан"
fi

# === 5. Initial commit + push ===
echo ""
echo "==> Step 5: initial commit + push"
git add .
if git diff --cached --quiet; then
    echo "ℹ️  Нечего commit'ить (repo уже на latest)"
else
    if [ -z "$(git config --get user.email)" ]; then
        git config user.email "home-ai-bot@local"
        git config user.name "home-ai-bot"
    fi
    git commit -m "Initial structure (v19 GIT_PROFILES_STORAGE 2026-05-18)"
    git push origin main 2>&1 | tail -3
    echo "✅ Pushed"
fi

# === 6. Verify final ===
echo ""
echo "==> Final state:"
echo "  Repo URL: https://github.com/$REPO_FULL"
echo "  Local:    $PROFILES_REPO"
echo "  Branch:   $(git rev-parse --abbrev-ref HEAD)"
echo "  Last commit: $(git log -1 --oneline)"
ls -la "$PROFILES_REPO"

echo ""
echo "✅ Setup завершён. Теперь можно запустить:"
echo "   /run_patch add-tools-v19-git-storage-profiles.sh"
echo "(он применит patches к bot.py с pre-flight check который пройдёт)"
