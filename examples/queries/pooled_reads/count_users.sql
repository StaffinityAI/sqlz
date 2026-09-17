-- sqlz.name: count_users
-- sqlz.backends: sqlite
-- sqlz.cardinality: one

SELECT COUNT(*) AS total FROM users;
