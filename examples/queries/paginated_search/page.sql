-- sqlz.name: page
-- sqlz.backends: sqlite
-- sqlz.cardinality: many

SELECT id, name FROM users WHERE name LIKE :pattern ORDER BY lower(name), id LIMIT :limit OFFSET :offset;
