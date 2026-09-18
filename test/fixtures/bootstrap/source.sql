PRAGMA foreign_keys = ON;

DROP TABLE IF EXISTS sessions;
DROP TABLE IF EXISTS profiles;
DROP TABLE IF EXISTS users;

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

INSERT INTO users VALUES
    (3, 'Ada', 1, 9.5, X'00FF'),
    (8, 'Lin', 0, NULL, NULL);

INSERT INTO profiles VALUES
    (3, 'compiler pioneer');

INSERT INTO sessions VALUES
    (5, 3, 'ada-live', 200, 0),
    (12, 8, 'lin-revoked', 300, 1);
