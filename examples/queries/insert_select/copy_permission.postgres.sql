-- sqlz.name: copy_permission
-- sqlz.backends: postgres
-- sqlz.cardinality: exec

INSERT INTO role_permissions(role_id, permission_key)
SELECT role_id, :new_key FROM role_permissions WHERE permission_key=:old_key
ON CONFLICT(role_id, permission_key) DO NOTHING;
