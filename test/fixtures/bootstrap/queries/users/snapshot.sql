-- sqlz.name: snapshot
-- sqlz.backends: sqlite, postgres
-- sqlz.cardinality: many

SELECT u.id, u.name, u.active, u.score, u.avatar, p.label
FROM users AS u
LEFT JOIN profiles AS p ON p.user_id = u.id
ORDER BY u.id;
