-- sqlz.name: create
-- sqlz.backends: sqlite, postgres
-- sqlz.cardinality: one

INSERT INTO users(name) VALUES (:name) RETURNING id, name;
