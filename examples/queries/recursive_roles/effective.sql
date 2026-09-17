-- sqlz.name: effective
-- sqlz.backends: sqlite
-- sqlz.cardinality: many

WITH RECURSIVE held(id, depth) AS (
  SELECT id, 0 FROM roles WHERE id=:role
  UNION ALL
  SELECT r.id, h.depth+1 FROM roles r JOIN held h ON r.child_id=h.id WHERE h.depth<:depth
)
SELECT id, depth FROM held ORDER BY depth;
