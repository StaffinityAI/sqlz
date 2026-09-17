//! Application types the example queries map onto.
//!
//! `sqlz.ziggy` registers `tier` as a codec accepting SQLite INTEGER, and
//! `build.zig` binds that ID to the declaration below, so checked queries can
//! name this enum instead of the `i64` the column actually stores.

pub const Tier = enum(i64) { basic = 0, premium = 1 };
