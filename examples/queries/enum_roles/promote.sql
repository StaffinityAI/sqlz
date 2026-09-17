-- sqlz.name: promote
-- sqlz.backends: sqlite
-- sqlz.cardinality: one
-- sqlz.param.tier: tier
-- sqlz.column.tier: tier

UPDATE accounts SET tier=:tier WHERE id=:id RETURNING id, name, tier;
