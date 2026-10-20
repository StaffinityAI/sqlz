# ADR 0042: Backend selection ownership

- Status: Accepted
- Date: 2026-10-20
- Refines: [ADR 0002](0002-lazy-static-backend-selection.md)

## Context

Backend choice is spread over three places: the `sqlz.ziggy` `.backends` map
selects checking profiles, the `sqlite`/`postgres` dependency options decide which
drivers are fetched and linked, and the executor type picks a query's SQL at
comptime. The configuration contract promised each registered project its own
runtime backend set, but `ProjectOptions` had none, so every project inherited the
dependency-wide set and nothing tied the enabled drivers to the checked dialects.
A build could link PostgreSQL for a project that never checks a PostgreSQL query.

## Decision

Each layer owns the one decision only it can make, and the build rejects a
combination the layers disagree on.

- `sqlz.ziggy` owns the checked dialects and profiles. It is versioned, offline,
  and readable by the CLI, and a backend may be checked without being executed.
- The dependency options own what is fetched and linked. Lazy dependencies are
  resolved when the consumer calls `b.dependency`, before any project file is
  known, so only the build can make this decision.
- `ProjectOptions.runtime` declares the backends a project executes and migrates
  against. It defaults to none. `addProject` panics at configure time when it
  names an adapter the dependency was configured without, and the check step fails
  with S020 when it names a backend without a checking profile.
- The executor type remains the only call-site selection.

The runtime facade stays one module per dependency. Zig admits a source file to
only one module per compilation, so per-project copies of the facade could not
coexist in an executable that imports several projects.

## Alternatives considered

Runtime dependency injection of a backend object needs the driver linked anyway,
adds dispatch cost, loses per-backend comptime SQL and row types, and reintroduces
the `AnyDatabase` ADR 0002 excludes. Selecting backends only with build options
leaves the offline checker and CLI without versioned dialect profiles. Selecting
them only in Ziggy cannot drive lazy fetching, because the dependency is
configured before the file's location is known. Root-module declarations in the
style of `std_options` are evaluated after fetching and are invisible to the
checker. A per-project facade module was rejected for the module-ownership rule
above.

## Consequences

A project must state its runtime set; registering one without `.runtime` produces
a checker-only project. The facade may export an adapter that a given project did
not enable when another project or the dependency options enabled it. The runtime
set reaches the check step as `--runtime` arguments; it does not narrow the shared
facade. Runtime migration bundles select backend SQL from it once they are
generated.

## Normative references

- [Build integration](../build-integration.md)
- [Configuration](../configuration.md)
