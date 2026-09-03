# Errors and observability

Fallible public runtime operations return `sqlz.Result(T)`, a tagged union with
`.ok: T` and `.err: sqlz.Error`. This permits structured backend payloads that a
Zig error union cannot carry.

## Error ownership

`sqlz.Error` owns variable-length data with the wrapper's allocator and requires
`deinit`. Helpers may inspect stable categories, operation, backend, retry hints,
SQLSTATE or SQLite code, constraint/table/column fields when supplied, and the full
native diagnostic. Moving or consuming a result transfers ownership; copying it is
invalid. Convenience APIs may discard detail explicitly.

Full backend messages are available to the caller and may contain SQL fragments,
identifiers, or user data. They must be treated as sensitive. Migration journals
store only safe context: category, numeric code or SQLSTATE, revision, direction,
and statement index—not backend messages, SQL, or parameters.

## Telemetry

Optional callbacks receive structured lifecycle events for acquisition, query
completion, migration operations, version overrides, and failures. Events contain
query ID, backend, duration, row count, safe category/code, and project/revision IDs
where applicable. They never contain SQL text, parameter values, credentials, or
full backend diagnostics. Callbacks are disabled by default and must not change
operation semantics.

Checker and CLI diagnostics are separate non-runtime values with stable codes,
source spans, labels, notes, and human or versioned JSON rendering.
