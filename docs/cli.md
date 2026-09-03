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

Migration lock acquisition defaults to 30 seconds and is configurable. Timeout is
a structured failure and never falls back to running unlocked.
