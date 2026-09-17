# Example sources

The examples are independent MIT-licensed rewrites of common query shapes. They
do not copy application modules or substantial SQL from their references.

- `account_crud`, `nullable_join`, `recursive_roles`, `transaction_transfer`,
  `session_lookup`, `aggregate_counts`, `insert_select`, and `delete_cleanup`
  were inspired by the unbuilt local
  `database-example.zig` reference.
- `account_crud` also follows the basic connection/row iteration shape shown by
  [zqlite](https://github.com/karlseguin/zqlite.zig).
- `preferences_upsert` represents the production upsert patterns discussed by
  [GRDB](https://github.com/groue/GRDB.swift) and
  [sqlc issue #3834](https://github.com/sqlc-dev/sqlc/issues/3834).
- `recursive_roles` represents the bounded hierarchy pattern demonstrated by
  [SQLite.swift](https://github.com/stephencelis/SQLite.swift/blob/master/Documentation/Index.md).
- `paginated_search` represents the ordered limit/offset query shapes used in
  [sqlc's end-to-end examples](https://github.com/sqlc-dev/sqlc/tree/main/internal/endtoend/testdata).
- `enum_roles`, `arena_rows`, and `pooled_reads` are original examples for the
  sqlz runtime surface itself: codec-mapped enums, arena-scoped owned rows, and
  pooled connections.
