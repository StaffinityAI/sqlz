# ADR 0032: `std.Io` at runtime initialization

- Status: Accepted
- Date: 2026-09-13

## Context

Zig 0.16 routes I/O and concurrency through a `std.Io` interface supplied by the
application. The host-side tools already thread it through. The runtime did not:
`sqlz.sqlite.open` took only an allocator, because SQLite is an in-process
blocking library that needs no interface.

The PostgreSQL backend does perform socket I/O, so it must run on the
application's interface rather than pick one. Applications also run on
third-party implementations such as [zio](https://github.com/lalinsky/zio), not
only `std.Io.Threaded`. Adding the parameter once PostgreSQL lands would break
every runtime entry point.

## Decision

Every sqlz runtime handle is initialized with an explicit `std.Io` and retains
it. `sqlz.sqlite.open(allocator, io, path)` stores `io` on the connection;
handles derived from a connection expose the same value. sqlz depends on the
interface only, never on a runtime implementation.

The interface is stored on the handle instead of being a per-call argument,
because generated bindings pass exactly one executor to each query and must not
grow a second threaded parameter. Streaming `Rows` carry their own copy, since
they outlive the call that produced them and a PostgreSQL cursor advances over
a socket. Materialized `Single` and `Owned` rows do not: their remaining work
is memory, not I/O.

The pinned `pg.zig` revision already has this exact shape —
`Conn.open(io, allocator, opts)` retains `_io: Io` while `query` and `exec`
take none — so the retained interface is handed straight to the driver.

## Alternatives considered

Passing `std.Io` per operation matches `std.Io.Dir`, but a connection is a
long-lived handle and the extra argument would reach every generated binding.
Deferring the parameter until the PostgreSQL backend exists was rejected as a
scheduled source break. Depending on a concrete runtime was rejected outright:
selecting an I/O implementation is the application's decision.

Wrapping every SQLite call in `io.async` was rejected. `async` does not mean
"offload": the vtable permits it to run the work eagerly and return null, and
zio implements it by spawning a coroutine on an executor thread, which a
blocking `sqlite3_step` then occupies. It relocates the stall rather than
removing it, while adding task spawn, stack, and await cost to calls often
measured in microseconds. Because sqlz returns results synchronously, every
such task would be awaited immediately, so no concurrency is gained. `std.Io`
exposes no blocking-work primitive to do this properly — the remedy is
runtime-specific (zio's `spawnBlocking` and `blockInPlace`, which use a real
thread pool). Wrapping would also advertise cancellation the backend cannot
honor, since `io.cancel` cannot interrupt `sqlite3_step` without
`sqlite3_interrupt`, and it would hold a live statement across suspension
points, which the borrowed-row rules in ADR 0009 do not permit.

## Consequences

Runtime entry points take an interface the SQLite backend does not yet use, and
the signature is stable for PostgreSQL. SQLite calls still block the calling
task; runtimes that offer a blocking-work escape hatch are documented as the
remedy rather than sqlz hiding one. zio is pinned as a lazy test-only
dependency so compatibility with a non-std implementation stays covered, for
the host pipeline as well as the runtime. `std.Io.Evented` is outside the claim
on Zig 0.16.0: on macOS it resolves to `std.Io.Dispatch`, whose `deinit` does
not compile in that release.

## Normative references

- [Runtime](../runtime.md)
