-- sqlz.name: find_session
-- sqlz.backends: sqlite
-- sqlz.cardinality: optional

SELECT u.id, u.name, s.csrf_token FROM sessions s JOIN users u ON u.id=s.user_id
WHERE s.token_hash=:token AND s.expires_at>:now;
