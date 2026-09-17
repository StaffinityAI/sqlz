# ADR 0033: Connection-scoped owned rows

- Status: Accepted
- Date: 2026-09-17

## Context

[ADR 0009](0009-borrowed-row-views-and-owned-conversion.md) makes rows borrowed
by default with an explicit allocator-backed conversion. The conversion took the
allocator per call and always produced a row that frees field by field, which
suits a general-purpose allocator and fits badly everywhere else.

Request-shaped applications already own an arena for the unit of work. Copying a
result set into that arena means passing the same allocator at every call site,
then writing a `deinit` per row that an arena makes pointless — and that is
actively wrong to call after the arena is released. Streaming results had no
owned conversion at all, so collecting a query into memory meant a hand-written
loop around `sqlz.cloneRow`.

## Decision

A connection carries an owned-row scope: `conn.ownedScope(allocator, options)`
directs allocator-less conversions at that allocator until the returned handle is
deinitialized. Scopes nest and restore the scope they replaced.

`toOwned` takes `?std.mem.Allocator`. An explicit allocator behaves exactly as
before and always owns the copy. `null` uses the scope, and no scope is an
`invalid_data` error rather than a silent allocation from an arbitrary allocator.

`ScopeOptions.free_rows = false` marks a scope that releases wholesale. Rows from
such a scope carry no allocator, so their `deinit` frees nothing while still
poisoning the handle. Streaming results gain `Rows.nextOwned` and
`Rows.collectOwned`, which follow the same rule.

Statement finalization is unaffected: `Single.deinit` and `Rows.deinit` stay
mandatory in every mode, because they release a SQLite statement rather than
memory. Error payloads keep using the connection's allocator and are not covered
by a scope.

## Alternatives considered

Keeping only the per-call allocator was rejected: it is what applications already
have, and it leaves both the repeated-argument problem and the misleading per-row
`deinit` in place. A distinct arena-flavored owned-row type would put the no-free
contract in the type rather than a connection setting, at the cost of doubling
every generated owned type. Making `deinit` infallible-but-wrong on an arena —
freeing into a released arena — was never an option.

## Consequences

An application can copy a whole result set into a request arena with one scope
and no per-row cleanup, and `sqlz.cloneRow` stops being the only path out of a
cursor. The scope is connection state, so a handle produced under one scope
keeps that scope's rules even if the connection is later rescoped. `Owned` rows
hold `?std.mem.Allocator`, which is a source-visible change from ADR 0009's
shape.

## Normative references

- [Checked query API](../query-api.md)
- [Runtime architecture](../runtime.md)
