-- ============================================================
-- Home AI Assistant Bot — SQLite schema
-- Создаётся при первом запуске setup-ai-server-p1.sh
-- ============================================================

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

-- ===== Whitelist пользователей бота =====
CREATE TABLE IF NOT EXISTS users (
    user_id        INTEGER PRIMARY KEY,         -- Telegram user_id
    username       TEXT,                         -- @username (без @), может быть NULL
    display_name   TEXT,                         -- Имя для логов / приветствия
    role           TEXT NOT NULL DEFAULT 'user', -- 'admin' | 'user'
    added_at       TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    added_by       INTEGER,                      -- user_id админа который добавил
    last_seen_at   TEXT,
    notes          TEXT                          -- произвольная заметка
);

CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);
CREATE INDEX IF NOT EXISTS idx_users_role ON users(role);

-- ===== История сообщений (conversation history per user) =====
CREATE TABLE IF NOT EXISTS messages (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id        INTEGER NOT NULL,
    direction      TEXT NOT NULL,                -- 'in' (user→bot) | 'out' (bot→user)
    role           TEXT NOT NULL,                -- 'user' | 'assistant' | 'system'
    content        TEXT NOT NULL,                -- текст сообщения
    model          TEXT,                          -- какая модель отвечала (для out)
    tokens_in      INTEGER,                       -- prompt tokens
    tokens_out     INTEGER,                       -- completion tokens
    duration_ms    INTEGER,                       -- время генерации
    ts             TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_messages_user_ts ON messages(user_id, ts DESC);

-- ===== Audit log выбора модели (double self-check) =====
CREATE TABLE IF NOT EXISTS model_routes (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id        INTEGER NOT NULL,
    message_id     INTEGER,                       -- ref на messages.id (in-сообщение)
    first_choice   TEXT NOT NULL,                 -- первый выбор: instruct/coder/vl
    second_check   TEXT NOT NULL,                 -- результат верификации: same/changed
    final_choice   TEXT NOT NULL,                 -- финальный выбор после double-check
    intent_label   TEXT,                          -- общий/код/картинка/смешанный
    confidence     REAL,                          -- 0.0-1.0 (если router возвращает)
    ts             TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE,
    FOREIGN KEY (message_id) REFERENCES messages(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_routes_user_ts ON model_routes(user_id, ts DESC);

-- ===== Usage stats / rate limits =====
CREATE TABLE IF NOT EXISTS usage_stats (
    user_id        INTEGER NOT NULL,
    bucket_hour    TEXT NOT NULL,                 -- ISO час: '2026-05-15T18'
    requests       INTEGER NOT NULL DEFAULT 0,    -- сколько сообщений в этом часе
    tokens_in      INTEGER NOT NULL DEFAULT 0,
    tokens_out     INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, bucket_hour),
    FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE
);

-- ===== Bot lifecycle / health =====
CREATE TABLE IF NOT EXISTS bot_lifecycle (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    event          TEXT NOT NULL,                 -- 'start' | 'stop' | 'error' | 'health'
    details        TEXT,                          -- JSON / free text
    ts             TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_lifecycle_ts ON bot_lifecycle(ts DESC);

-- P4-mini: per-user долгосрочный профиль (вкладывается в system prompt)
CREATE TABLE IF NOT EXISTS user_profiles (
    user_id    INTEGER PRIMARY KEY,
    profile_md TEXT    NOT NULL DEFAULT '',
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
