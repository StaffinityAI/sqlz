-- sqlz.name: save
-- sqlz.backends: sqlite, postgres
-- sqlz.cardinality: one

INSERT INTO preferences(user_id, value) VALUES (:user_id, :value)
ON CONFLICT(user_id) DO UPDATE SET value=excluded.value RETURNING user_id, value;
