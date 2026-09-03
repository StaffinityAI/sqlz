# Performance plan

Performance gates are established from reproducible baselines before 0.1
stabilization, not guessed during initial design.

## Benchmarks

The suite measures cold and warm checking for small, medium, and large projects;
lexer/parser throughput; migration replay over linear and branching graphs;
generated-code size and Zig compile time; single-row and streaming decode overhead;
pool acquire/release; and migration planning/state writes. Inputs, engine images,
hardware class, release build mode, repetitions, and statistical summaries are
versioned with the suite.

Baselines compare sqlz wrappers with direct zqlite/pg.zig operations where a fair
equivalent exists. Peak resident memory and allocation counts accompany elapsed
time. Checker cache hits and misses are reported separately.

Before 0.1 stabilization, maintainers record baseline results and adopt numeric
release gates for regression percentage, variance, memory, and generated-code
growth. Until then, benchmark movement is reported but is not presented as a
compatibility guarantee.
