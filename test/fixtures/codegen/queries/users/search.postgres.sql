-- sqlz.name: search_users
-- sqlz.backends: postgres
-- sqlz.cardinality: many

SELECT id, name FROM users WHERE name ILIKE :pattern;
