-- sqlz.name: count_users
-- sqlz.backends: sqlite, postgres
-- sqlz.cardinality: one

SELECT COUNT(*) AS total FROM users;
