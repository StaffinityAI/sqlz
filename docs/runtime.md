# Runtime architecture

sqlz provides thin typed wrappers over `zqlite` and `pg.zig`. Drivers continue to
own sockets, wire protocols, preparation, statement caches, and pooling. sqlz owns
checked bindings, decoding, consistent result/error shapes, and migration behavior.

## `std.Io` and runtimes

sqlz does not own an I/O runtime and never selects one. Every connection is
initialized with the `std.Io` the application already runs on, and the handle
retains it:

```zig
var conn = try sqlz.sqlite.open(allocator, io, "app.db");
defer conn.deinit();
```

`io` may be `std.Io.Threaded` or any third-party implementation of the
interface, such as [zio](https://github.com/lalinsky/zio):

```zig
const runtime = try zio.Runtime.init(allocator, .{});
defer runtime.deinit();

var conn = try sqlz.sqlite.open(allocator, runtime.io(), "app.db");
```

The interface is stored on the connection rather than passed per call because
generated bindings take exactly one executor argument. Handles derived from a
connection reach the same implementation: `Transaction.io()` returns the
connection's, streaming `Rows` carry a copy because they outlive the call that
produced them, and the field is readable as `conn.io` for escape hatches.
Materialized handles — `Single` and `Owned` rows — deliberately do not carry
it: their remaining work is memory, not I/O.

`std.Io.Evented` is not a supported target on Zig 0.16.0. It resolves to
`std.Io.Dispatch` on macOS, whose `deinit` does not compile in that release, so
sqlz makes no claim about it.

SQLite is an in-process blocking library, so the SQLite backend performs no
`std.Io` operations of its own; a long SQLite call occupies whichever task
invokes it. Runtimes that offer a blocking-work escape hatch (for example
zio's `spawnBlocking` and `blockInPlace`) can keep the scheduler responsive.
The PostgreSQL backend does perform socket I/O and will use the retained
interface, which is why it is required at initialization now rather than added
later as a breaking change.

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
