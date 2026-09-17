-- sqlz.name: cleanup
-- sqlz.backends: sqlite
-- sqlz.cardinality: exec

DELETE FROM sessions WHERE expires_at<=:now;
