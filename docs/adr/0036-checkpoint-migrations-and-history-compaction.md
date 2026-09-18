# ADR 0036: Checkpoint migrations and history compaction

- Status: Proposed
- Date: 2026-09-18

## Context

Long-lived projects accumulate migrations that are useful for upgrading existing
databases but expensive and noisy for creating new databases. Branch merge
revisions solve multiple graph heads; they do not replace an old ancestor closure
with one current-state bootstrap. Editing or deleting applied history without an
explicit protocol conflicts with sqlz checksums, parent identity, downgrade
behavior, journals, and partially upgraded deployments.

## Decision

Add checkpoint revisions as an alternate path for creating an empty database at
the schema state of a closed historical ancestor set. A checkpoint declares one
`through` revision and the exact revisions it replaces. It has no parents, is
forward-only in 0.1, targets one or more backends, and contains ordinary static SQL.

The checker replays both paths for every targeted backend and requires catalog
equivalence:

```text
catalog(original ancestor closure through R) == catalog(checkpoint for R)
```

Equivalence proves schema shape only. Checkpoints are valid only for an empty
destination and do not claim to reproduce historical DML effects for an existing
database.

If a checkpoint targets fewer backends than `through`, it is eligible only for the
named backends and does not compact the others. Finalization may prune a historical
revision only when every backend that revision targets is covered by an accepted
checkpoint at the same logical boundary; partial backend coverage therefore cannot
remove shared/common history.

Historical and checkpoint paths coexist during a transition period:

- a database with no applied sqlz migration history may select the unique maximal
  eligible checkpoint and
  continue with descendants after `through`;
- a database with any applied historical revision continues on historical edges
  and never jumps to the checkpoint;
- a database already at or beyond `through` records checkpoint equivalence during
  a normal state upgrade or explicit adoption command, without executing checkpoint
  SQL;
- descendants after `through` depend on the historical revision identity, not the
  checkpoint revision, so both paths converge on one logical continuation;
- checkpoint selection and adoption are recorded in durable state and journals.

Old source revisions may be removed only by a separate confirmed finalization
workflow after operators have established that every maintained deployment has
crossed the checkpoint boundary. Durable replacement identity remains readable
after source pruning so existing databases do not become unknown histories.

Finalization writes a versioned repository artifact at
`migrations/history.ziggy`. It records each pruned revision ID, parent set,
manifest/content checksum, replacement checkpoint, and logical `through` boundary,
but no executable SQL. The file is a normal checked build input and is embedded in
runtime migration metadata. It makes intentionally pruned applied IDs recognizable;
it does not make their SQL executable. A deployment still below the finalized
boundary therefore fails with a specific pruned-history-unavailable error and must
restore an older source release or be repaired by an operator.

After pruning, registry entries act as non-executable virtual historical nodes.
Offline checking and planning reconstruct the current catalog by loading the
validated checkpoint snapshot at `through` and replaying live descendants. A later
checkpoint may compact farther forward only after the earlier one is finalized; its
replacement closure includes the virtual pruned IDs from `history.ziggy` plus the
live descendant IDs through the new boundary. Verification composes the earlier
checkpoint proof with replay of the live suffix. Checkpoint IDs themselves never
become logical migration ancestors.

Checkpoint support requires a new migration manifest format version. Format 1
continues to mean an ordinary immutable revision. The new format adds a tagged
checkpoint declaration with `through`, an exact canonical replacement set, and
scope fixed to `empty_database` for the first implementation.

An empty destination may already contain initialized sqlz internal state tables.
Eligibility requires an empty applied set, no incomplete migration command, no
checkpoint/adoption record, and no user objects in the configured managed
namespaces. Backend/system objects and sqlz's own internal state objects are
ignored. Any other object or data outside explicitly allowed internal state rejects
checkpoint bootstrap.

## Alternatives considered

Naively deleting old migrations and stamping databases was rejected because it
silently rewrites applied history. Treating a checkpoint as a normal merge revision
was rejected because merge revisions join heads but still require their ancestors.
Automatically generating a checkpoint from the catalog was rejected for the first
implementation because static
SQL can include backend-specific objects, opaque statements, and reviewed intent
that a schema serializer cannot safely reconstruct. Requiring every new database to
replay all history was retained as a valid mode but rejected as the only mode.

## Consequences

Fresh database creation can become fast without weakening immutable history for
existing databases. The planner, state schema, checksums, runtime bundle, CLI, and
compatibility policy must understand replacement identity. Checkpoint SQL is
security-sensitive deployment code and finalization is destructive. Downgrading
across a checkpoint boundary is unsupported in the first implementation; operators
must retain the historical path when that downgrade capability is required.

## Normative references

- [Migrations](../migrations.md)
- [Migration state](../migration-state.md)
- [CLI](../cli.md)
- [Compatibility](../compatibility.md)
- [Security](../security.md)
- [Testing](../testing.md)
