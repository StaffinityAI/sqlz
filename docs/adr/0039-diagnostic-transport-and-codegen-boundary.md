# ADR 0039: Diagnostic transport and codegen boundary

- Status: Accepted
- Date: 2026-09-18

## Context

ADR 0020 requires stable codes, source spans, labels, notes, human rendering,
versioned JSON, and defined exit behavior. The current checker and code generator
propagate plain Zig errors through `main`, producing unstable stack-oriented output
and no machine contract. Converting every parser, catalog, and analyzer error in one
change would be too broad, but the public process boundary needs a stable transport
before those components can migrate incrementally.

## Decision

Introduce a backend-neutral diagnostics module containing borrowed diagnostic
records: severity, stable code, message, optional primary source span, ordered
labels, notes, and help text. Source spans use workspace-relative paths, byte
offsets, and one-based line/column coordinates. Diagnostics render to any
`std.Io.Writer` as human text or one JSON object per line with
`format_version = 1`.

The codegen executable owns CLI parsing and maps invocation failures to exit 2,
checked project/source failures to exit 1, and successful generation to exit 0.
JSON mode writes diagnostics only to stdout; human diagnostics use stderr. Until
components return rich diagnostics directly, the boundary maps their stable Zig
error names into grouped top-level codes and includes the error name as a note.
That compatibility mapping is transitional but versioned and unit tested.

Rendering is allocation-free beyond caller-provided writer buffers. Diagnostic
values borrow source/message storage for the duration of rendering; aggregators that
need longer lifetimes own that storage separately. Labels and notes preserve caller
order so rendering remains deterministic.

## Alternatives considered

Continuing to print `@errorName` was rejected because it provides no source or JSON
contract. Allocator-owned diagnostic objects everywhere were rejected as the base
transport because many errors borrow already-owned source buffers. Converting all
checker internals before defining the renderer was rejected because each component
would otherwise invent a different shape.

## Consequences

The executable output and exit statuses become stable immediately, while rich spans
can be adopted component by component. Error-code mappings become compatibility
surface and require golden tests. Build integrations must pass `--format` explicitly
when machine output is needed and must not mix progress with JSON stdout.

## Normative references

- [SQL checker](../sql-checker.md)
- [CLI](../cli.md)
- [Errors and observability](../errors-and-observability.md)
- [ADR 0020](0020-source-oriented-diagnostics-and-machine-output.md)
