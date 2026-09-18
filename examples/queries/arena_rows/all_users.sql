-- sqlz.name: all_users
-- sqlz.backends: sqlite, postgres
-- sqlz.cardinality: many

SELECT id, name FROM users ORDER BY id;
