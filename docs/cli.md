# Build-integrated CLI

The single command surface is `zig build sqlz -- <command>`. There are no separate
`sqlz-check` or `sqlz-migrate` top-level steps.

## Commands

```text
zig build sqlz -- init
zig build sqlz -- check [--project NAME] [--format human|json]
zig build sqlz -- status [--project NAME] --backend NAME
zig build sqlz -- migrate upgrade TARGET [connection options]
zig build sqlz -- migrate downgrade TARGET [connection options]
zig build sqlz -- revision create [--message TEXT]
zig build sqlz -- revision merge REV...
zig build sqlz -- checkpoint create --through REV [--message TEXT]
zig build sqlz -- checkpoint verify CHECKPOINT
zig build sqlz -- checkpoint adopt CHECKPOINT [connection options]
zig build sqlz -- checkpoint finalize CHECKPOINT
zig build sqlz -- bootstrap postgres --from-sqlite PATH [--postgres-url URL]
    [--project NAME] [--wipe-postgres --yes]
zig build sqlz -- state init|stamp|repair|rebind
zig build sqlz -- journal show|prune
```

The build installs/runs one host tool and registers all projects with it. `--project`
is inferred only when exactly one registration is applicable.

## Output contract

Human output is concise and source-oriented. `--format json` writes only a
versioned stream of JSON records to stdout; progress and human diagnostics go to
stderr. Records contain `format_version`, kind, stable code, project, backend, and
command-specific payload. Exit status is zero only when the requested operation
completed and all requested checks passed.

## Safety

Read-only commands never prompt. Destructive or history-asserting operations—such
as downgrade, stamp, repair, rebind, and journal prune—prompt on an interactive
terminal. Non-interactive use must pass `--yes`; otherwise the command fails before
opening a mutation transaction. Secrets are accepted through driver-appropriate
environment/config channels and are redacted from output.

`bootstrap postgres` is the first implemented operational command. It requires
both backend dependencies, a registered project with SQLite and PostgreSQL
profiles, and a dedicated single-entry PostgreSQL `search_path` other than
`public`. The destination URL comes from `--postgres-url` or `DATABASE_URL`.
Without `--wipe-postgres`, an existing managed destination is rejected. The
initial implementation requires `--yes` with `--wipe-postgres`; interactive
confirmation, JSON output, migration-state recording, and nontransactional
migration support remain pending.

`checkpoint create` generates a manifest/directory skeleton and authors supply
reviewed SQL; schema serialization/autogeneration remains out of scope. Creation
never edits or deletes historical files. A checkpoint containing DML requires an
explicit `--acknowledge-unverified-dml` during verification/finalization, and the
acknowledgement is recorded in command output and journal metadata.
`checkpoint verify` is read-only and checks replacement closure plus per-backend
catalog equivalence. `checkpoint adopt` records equivalence on a database already
at or beyond `through` and executes no checkpoint SQL. `checkpoint finalize` is a
destructive repository-history workflow: it prints the exact removable revisions,
requires `--yes` in non-interactive use, emits durable replacement tombstone
metadata, and leaves source deletion to a separate explicit version-control change.
It must never infer that unknown remote deployments are safe to prune.

Fresh migration commands report whether they selected historical replay or a
checkpoint bootstrap. `--no-checkpoint` forces historical replay for testing and
for operators who retain downgrade-from-base requirements. There is no flag that
allows a partially migrated database to jump into a checkpoint.

`status`, `history`, human plans, and JSON plans distinguish physical execution
from logical coverage. A checkpoint-bootstrapped database reports the checkpoint
ID and `through` boundary, then lists replaced ordinary revisions as covered, not
individually executed. `stamp` cannot create checkpoint adoption evidence;
operators use `checkpoint adopt` so replacement fingerprints are verified and
journaled.

Migration lock acquisition defaults to 30 seconds and is configurable. Timeout is
a structured failure and never falls back to running unlocked.
