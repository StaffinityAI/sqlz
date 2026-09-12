-- sqlz.name: get_user
-- sqlz.backends: sqlite
-- sqlz.cardinality: optional

SELECT id, name FROM users WHERE id=:id;
