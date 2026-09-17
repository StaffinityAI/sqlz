# ADR 0034: Typed SQLite connection options and the pool wrapper

- Status: Accepted
- Date: 2026-09-17

## Context

`sqlz.sqlite.open` hardcoded its open flags and applied no PRAGMA at all, so
every application configured `foreign_keys`, `journal_mode`, `synchronous`, and
the busy timeout through `raw()` — the same four statements, written once per
project, easy to forget on the second connection.

[Runtime architecture](../runtime.md) already commits sqlz to wrapping the
driver's native pool rather than implementing one, and
[the query API](../query-api.md) already names `sqlz.sqlite.Pool` as a public
executor, but neither existed. A pool makes the configuration question sharper:
pooled connections are opened by the driver, so an application cannot configure
them after the fact.

## Decision

`OpenOptions` names the connection settings sqlz applies on the caller's behalf:
open flags (`create`, `read_only`), `foreign_keys`, `journal_mode`,
`synchronous`, and `busy_timeout_ms`. Every field is optional and `null` leaves
SQLite's own default in place; anything not named stays a `raw()` PRAGMA. They
are applied in a fixed order, the busy timeout first, so a contended
journal-mode switch waits instead of failing.

`sqlz.sqlite.Pool` wraps zqlite's native pool. sqlz contributes no scheduling,
no sizing policy, and no statement cache: `init` hands the driver the same
typed options as a callback, `acquire` returns an ordinary `sqlz.sqlite.Conn`,
and that connection's `deinit` releases it. Connection ownership is therefore
three-valued — `owned` closes, `borrowed` does nothing, `pooled` releases.

`Pool` also implements the executor protocol, so a checked query can run against
it directly. Cardinalities that return a live handle transfer the borrowed
connection to that handle, which releases it on `deinit`; `execute` releases
immediately.

## Alternatives considered

Exposing only open flags and leaving PRAGMAs to `raw()` keeps sqlz out of SQLite
policy, but leaves pooled connections unconfigurable except through a
driver-typed callback, which is the layering the wrapper exists to remove. A
free-form PRAGMA list was rejected: it is an unchecked string interface in a
library whose purpose is checked SQL. Implementing a pool was rejected by the
existing design, and nothing here changes that — the type is a wrapper.

## Consequences

`open` takes an options argument, a source break for every call site. Common
SQLite configuration is now typed, discoverable, and applied identically to
pooled and unpooled connections. A pooled handle that outlives its pool is a
use-after-release, which is why release lives in exactly one place per handle
type. Options sqlz does not name remain available through `raw()`.

## Normative references

- [Runtime architecture](../runtime.md)
- [Checked query API](../query-api.md)
