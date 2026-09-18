-- sqlz.name: cleanup
-- sqlz.backends: sqlite, postgres
-- sqlz.cardinality: exec

DELETE FROM sessions WHERE expires_at<=:now;
