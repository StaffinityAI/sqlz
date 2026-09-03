# SQL type system

The analyzer models database type identity, nullability, literals, operators,
functions, parameters, rows, and custom codecs independently of Zig runtime types.
Backend adapters then map checked database types to generated Zig types.

## Inference and coercion

Type variables collect constraints from casts, columns, operators, functions,
assignments, comparisons, and result context. Overload resolution accepts exact
matches first and then only documented lossless implicit coercions. It reports
ambiguity instead of choosing a narrowing, lossy, locale-dependent, or
backend-dependent conversion. Untyped NULL and string/numeric literals remain
unknown until constrained.

Repeated named parameters are one logical value and all occurrences must unify.
A parameter that remains ambiguous requires an explicit cast. Result columns have
stable names, database identities, Zig mappings, and inferred nullability.

## Nullability

Schema constraints seed nullability. Outer joins, nullable expressions, aggregate
rules, CASE, UNION-like operations, and function contracts transform it. A query
annotation may tighten only when the checker can prove the claim; an explicit
runtime-validation annotation may request a checked narrowing and possible runtime
error.

## SQLite

STRICT tables receive the strongest guarantees. Non-STRICT tables are supported
with one schema-level warning per affected object. Generated decoders validate the
observed storage class and numeric range, returning a typed runtime error on a
mismatch rather than coercing silently.

## PostgreSQL arrays

0.1 supports one-dimensional typed arrays, including null arrays and nullable
elements where declared. Borrowed rows expose an iterator over the wire value;
owned rows collect elements with an allocator. Multidimensional arrays are a
checker error in 0.1.

## Catalog polymorphism and codecs

Catalog signatures support simple type variables, equality constraints,
nullability relations, and array-element relationships. Complex PostgreSQL
builtins use reviewed checker intrinsics; sqlz does not attempt the complete server
polymorphism model in 0.1. Custom codec IDs connect database patterns in Ziggy to
one build-time Zig implementation and participate in the same constraint system.
