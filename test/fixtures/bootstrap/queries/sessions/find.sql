-- sqlz.name: find
-- sqlz.backends: sqlite, postgres
-- sqlz.cardinality: optional

SELECT s.id, u.name, s.expires_at, s.revoked
FROM sessions AS s
JOIN users AS u ON u.id = s.user_id
WHERE s.token_hash = :token;
