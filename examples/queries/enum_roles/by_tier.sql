-- sqlz.name: by_tier
-- sqlz.backends: sqlite
-- sqlz.cardinality: many
-- sqlz.param.tier: tier
-- sqlz.column.tier: tier

SELECT id, name, tier FROM accounts WHERE tier=:tier ORDER BY id;
