-- sqlz.name: create
-- sqlz.backends: sqlite, postgres
-- sqlz.cardinality: one

INSERT INTO users(name, active) VALUES (:name, :active)
RETURNING id, name, active;
