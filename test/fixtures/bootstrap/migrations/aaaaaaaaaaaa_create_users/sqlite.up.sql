CREATE TABLE users (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    active BOOLEAN NOT NULL,
    score REAL,
    avatar BLOB
);

CREATE TABLE profiles (
    user_id INTEGER PRIMARY KEY REFERENCES users(id),
    label TEXT
);

CREATE TABLE sessions (
    id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id),
    token_hash TEXT NOT NULL UNIQUE,
    expires_at INTEGER NOT NULL,
    revoked BOOLEAN NOT NULL
);
