-- sqlz.name: transfer
-- sqlz.backends: sqlite, postgres
-- sqlz.cardinality: exec

UPDATE workspaces SET owner_id=:new_owner WHERE id=:workspace AND owner_id=:old_owner;
