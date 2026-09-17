-- sqlz.name: create
-- sqlz.backends: sqlite
-- sqlz.cardinality: one

INSERT INTO users(name) VALUES (:name) RETURNING id, name;
