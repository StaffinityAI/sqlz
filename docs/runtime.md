# Runtime architecture

sqlz provides thin typed wrappers over `zqlite` and `pg.zig`. Drivers continue to
own sockets, wire protocols, preparation, statement caches, and pooling. sqlz owns
checked bindings, decoding, consistent result/error shapes, and migration behavior.

## Handles and ownership

Each backend exposes distinct borrowed and owned connection wrappers. An owned
wrapper closes/releases its native handle on `deinit`; a borrowed wrapper never
does. Pool wrappers delegate acquisition and scheduling to the driver's native
pool and return sqlz connection wrappers with explicit release semantics.

Transactions are move-only logical handles. `commit` and `rollback` return detailed
results. `deinit` rolls back an active transaction; if rollback fails, the
connection is poisoned and discarded rather than returned to a pool.

## Executors

Generated queries accept a sealed sqlz executor interface implemented by sqlz
connections and transactions. Raw driver handles do not satisfy it accidentally.
Backend-specific escape hatches are explicit methods returning the native handle
and give up sqlz portability guarantees for that operation.

0.1 offers no portable cancellation, query timeout, fetch-size, or generic query
options API. Applications use an explicit backend escape hatch when needed.

## Rows and streams

Borrowed row values remain valid only until the next cursor advance, statement
reset, or owning result deinitialization. `row.toOwned(allocator)` copies all
borrowed text, blobs, arrays, and codec-owned data and requires `deinit`. Streaming
iterators own or borrow the executing handle exactly as stated by their type and
must be finalized.

sqlz does not add a statement cache or promise transparent reprepare. Stable query
IDs may be passed to drivers that support caching, but preparation behavior and
schema-change recovery remain driver-defined.
