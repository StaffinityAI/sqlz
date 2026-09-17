# ADR 0035: Derived enum codecs

- Status: Accepted
- Date: 2026-09-17

## Context

[ADR 0014](0014-custom-codecs-and-split-registration.md) defines codecs as a
stable ID with database patterns in `sqlz.ziggy` and a `{module, declaration}`
binding in `build.zig`, and [the query API](../query-api.md) says enums and ID
newtypes should use codecs rather than converting at every call site.

The codec contract there is written for arbitrary types: a declaration supplies
`Value`, `Owned`, `borrows_result`, and a bind/decode pair per backend. For an
integer- or text-backed enum every one of those is mechanical, and requiring an
application to write them is how `enum(i64)` columns end up as `i64` in
application code with a hand-rolled conversion at each boundary.

## Decision

sqlz derives the codec for a Zig enum. Registration is unchanged — the ID and
its database patterns live in `sqlz.ziggy`, `build.zig` binds the ID to one
declaration — but when that declaration is an enum, no encode/decode pair is
written by anyone: the runtime converts through the enum's integer tag, or
through its name when the enum declares `pub const sqlz_storage = .text`.

A database value outside the enum is a decode error carrying `invalid_data`, not
a trap and not an inferred tag.

Enums are also recognized without any registration in hand-written queries,
where the row and parameter structs are the application's own types. Registration
exists so that *generated* code can name an application type; it is not a
precondition for using an enum at the boundary.

The generated module asserts the contract at the consumer's compilation with
`sqlz.assertCodec`. In this slice that assertion rejects every non-enum
declaration, which keeps a partially implemented codec interface from appearing
to work.

## Alternatives considered

Requiring hand-written `bindSqlite`/`decodeSqlite` for enums follows the general
contract, but the implementations are derivable and the boilerplate is precisely
what the feature is meant to remove. A separate `.enums` registration table
alongside codecs was rejected as a second mechanism for the problem codecs
already own. Recognizing enums only through registration was rejected: a
hand-written query names its own types, and nothing there needs an ID.

## Consequences

An application maps an `enum(i64)` column by registering one ID and binding it to
the enum, and generated parameters and rows then name that enum directly. The
general codec interface is still unimplemented, and `assertCodec` says so at
compile time. Storage choice is a property of the enum rather than of the
column, so one enum is stored one way across every query that uses it.

## Normative references

- [Checked query API](../query-api.md)
- [Project configuration](../configuration.md)
- [Type system](../type-system.md)
