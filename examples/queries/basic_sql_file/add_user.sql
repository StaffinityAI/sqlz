-- sqlz.name: add_user
-- sqlz.backends: sqlite, postgres
-- sqlz.cardinality: exec

INSERT INTO users(name) VALUES (:name);
