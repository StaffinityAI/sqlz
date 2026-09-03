# Migration state and journal

Each database stores project identity, semantic configuration identity, applied
revisions, and an append-only operation journal. This separates durable schema
state from interrupted-command evidence.

## Internal schema

PostgreSQL uses a dedicated configurable schema named `sqlz` by default. sqlz
creates it when permitted; `zig build sqlz -- state init` is the explicit fallback
for restricted deployments. SQLite uses reserved tables in `main`.

The logical tables are:

- metadata: state format version, canonical project UUID, semantic configuration
  fingerprint, and creation/upgrade timestamps;
- applied revisions: revision ID, content/effective-SQL checksums, application
  time, and parent set;
- command runs: run ID, command/direction/target, start/end state, actor-safe
  metadata, and terminal status;
- revision steps: run ID, ordered revision and statement index, timestamps,
  outcome, and safe error category/code.

Physical names and DDL are versioned implementation details. State upgrades are
automatic, forward-only, transactional, and performed under the migration lock.
An unsupported newer state version is rejected.

## Identity and fingerprints

The database project UUID must equal `sqlz.ziggy`. A semantic fingerprint covers
configuration that changes migration interpretation, excluding paths and cosmetic
settings. Mismatches fail closed. Rebinding requires an explicit command,
interactive confirmation or `--yes`, and a journal entry.

Applied revision checksums detect edits. Parent identity is stored so graph-history
rewrites cannot masquerade as equivalent files.

## Dirty operations

An applied set is updated only at successful transaction boundaries. Every command
also writes a run plus ordered per-revision steps, making interrupted or partially
transactional backend operations visible without inventing a single global dirty
bit. Recovery commands inspect both structures and require explicit operator
choice.

The journal is retained indefinitely by default. `journal prune` is an explicit
destructive command, records its cutoff where possible, and follows CLI confirmation
rules.
