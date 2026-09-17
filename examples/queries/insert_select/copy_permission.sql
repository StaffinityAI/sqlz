-- sqlz.name: copy_permission
-- sqlz.backends: sqlite
-- sqlz.cardinality: exec

INSERT OR IGNORE INTO role_permissions(role_id, permission_key)
SELECT role_id, :new_key FROM role_permissions WHERE permission_key=:old_key;
