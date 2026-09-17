-- sqlz.name: counts
-- sqlz.backends: sqlite
-- sqlz.cardinality: one

SELECT (SELECT COUNT(*) FROM organization_members WHERE user_id=:user)
     + (SELECT COUNT(*) FROM workspace_members WHERE user_id=:user) AS total;
