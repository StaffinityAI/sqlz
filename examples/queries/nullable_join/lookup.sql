-- sqlz.name: lookup
-- sqlz.backends: sqlite
-- sqlz.cardinality: optional

SELECT u.name, p.label FROM users u LEFT JOIN profiles p ON p.user_id=u.id WHERE u.id=:id;
