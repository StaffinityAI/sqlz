DROP TABLE IF EXISTS users;
CREATE TABLE users (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    active BOOLEAN NOT NULL,
    score REAL,
    payload BLOB
);
INSERT INTO users VALUES
    (3, 'Ada', 1, 9.5, X'00FF'),
    (8, 'Lin', 0, NULL, NULL);
