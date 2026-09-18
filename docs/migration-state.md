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

Checkpoint-aware state also stores:

- the checkpoint revision used to bootstrap an empty database, when any;
- its `through` revision, replacement-set digest, and checkpoint SQL checksum;
- adopted checkpoint equivalences for databases that followed the historical
  path through the same boundary;
- finalized replacement tombstones needed to interpret applied revisions after
  old source files are intentionally removed.

Physical names and DDL are versioned implementation details. State upgrades are
automatic, forward-only, transactional, and performed under the migration lock.
An unsupported newer state version is rejected.

The first state format that supports checkpoints adds bootstrap/adoption records
and replacement tombstones in one atomic state upgrade. Implementations must not
encode checkpoint adoption by fabricating ordinary applied-revision rows: the two
facts have different execution and audit meaning.

## Identity and fingerprints

The database project UUID must equal `sqlz.ziggy`. A semantic fingerprint covers
configuration that changes migration interpretation, excluding paths and cosmetic
settings. Mismatches fail closed. Rebinding requires an explicit command,
interactive confirmation or `--yes`, and a journal entry.

Applied revision checksums detect edits. Parent identity is stored so graph-history
rewrites cannot masquerade as equivalent files.

Checkpoint identity does not erase historical identity. A database bootstrapped
from a checkpoint stores both the checkpoint evidence and the logical historical
boundary it represents. A database that applied the historical path stores its
ordinary applied revisions and may later adopt the same checkpoint equivalence
without executing checkpoint SQL. Replacement-set and catalog fingerprints must
match exactly; adoption fails closed on drift.

Logical coverage through `through` is derived from checkpoint evidence and the
replacement set; implementations do not insert fabricated applied rows for each
replaced revision. Planner/status APIs expose physical applied revisions,
checkpoint evidence, and derived covered revisions as distinct collections.

The checkpoint fingerprint covers the checkpoint manifest and effective SQL,
ordered replacement IDs, every replaced revision's canonical parent set and
manifest/content checksums, per-backend catalog snapshot fingerprints, checkpoint
scope, backend profiles, semantic project configuration, and compacted-history
registry checksum. Cosmetic paths and descriptions remain excluded under the
ordinary semantic-fingerprint rules.

When source history has been finalized and pruned, durable tombstones allow the
state reader to recognize intentionally replaced revision IDs. An unknown revision
not covered by a matching tombstone remains an error. State format upgrades that
add checkpoint metadata are automatic, forward-only, transactional, and performed
under the migration lock.

Database tombstones are checked against the repository's versioned
`migrations/history.ziggy` registry. The registry entry includes the original
revision parent set and checksums, so a same-ID rewrite cannot be mistaken for an
intentional prune. A database below a finalized boundary is recognizable but not
upgradeable by the pruned source tree; recognition must not be confused with having
the missing executable migration SQL.

## Dirty operations

An applied set is updated only at successful transaction boundaries. Every command
also writes a run plus ordered per-revision steps, making interrupted or partially
transactional backend operations visible without inventing a single global dirty
bit. Recovery commands inspect both structures and require explicit operator
choice.

Checkpoint selection, adoption, and finalization each create command-run journal
entries. Journals record IDs and safe digests, not migration SQL. A failed
checkpoint bootstrap leaves no applied boundary; partially executed nontransactional
checkpoint SQL follows the same statement journal and explicit repair rules as an
ordinary `never` revision.

The journal is retained indefinitely by default. `journal prune` is an explicit
destructive command, records its cutoff where possible, and follows CLI confirmation
rules.
