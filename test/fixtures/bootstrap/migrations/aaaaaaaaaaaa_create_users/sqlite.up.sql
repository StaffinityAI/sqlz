CREATE TABLE users (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    active BOOLEAN NOT NULL,
    score REAL,
    payload BLOB
);
