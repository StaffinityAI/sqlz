# Builtin catalogs and supplements

SQL checking is offline and deterministic. It uses checked-in, reviewed Ziggy
catalogs selected by backend profile, never a live development database.

## Builtin catalogs

Each supported SQLite version/capability profile and PostgreSQL major has a
versioned catalog describing scalar and aggregate functions, operators, casts,
types, relevant pragmas, and semantic flags. Generation scripts may extract facts
from upstream engines, but generated changes are reviewed and committed. Every
entry records provenance and its supported profile range.

## Supplements

Projects may add versioned Ziggy supplements for extensions and application
functions. A supplement declares stable IDs, backend/profile constraints, types,
signatures, nullability, volatility where relevant, and codec patterns. It cannot
silently replace a builtin. Duplicate identities and overlapping signatures are
errors unless an explicit, exact override of a supplement from the same project is
declared.

Resolution order is schema objects reconstructed from migrations, project
supplements, then builtins; overload selection is based on types rather than file
order. The effective catalog and all supplement content contribute to the checker
cache key and semantic configuration fingerprint.

## Ziggy dependency

sqlz pins Ziggy commit `6760f0f4c4fc1ae01428bc6d87109e32124eeeb7`, verified
with Zig 0.16.0. Updating that pin requires format fixture tests and an ADR when it
changes persisted syntax or compatibility.
