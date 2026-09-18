-- sqlz.name: get_user
-- sqlz.backends: sqlite, postgres
-- sqlz.cardinality: optional

SELECT id, name FROM users WHERE id=:id;
