-- sqlz.name: search_users
-- sqlz.backends: sqlite
-- sqlz.cardinality: many

SELECT id, name FROM users WHERE name LIKE :pattern;
