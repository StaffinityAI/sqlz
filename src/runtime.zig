const options = @import("sqlz_runtime_options");
const core = @import("sqlz_core");

pub const Backends = core.Backends;
pub const Cardinality = core.Cardinality;
pub const ExecResult = core.ExecResult;
pub const ErrorClass = core.ErrorClass;
pub const Backend = core.Backend;
pub const Error = core.Error;
pub const Operation = core.Operation;
pub const Result = core.Result;
pub const Query = core.Query;
pub const unwrap = core.unwrap;
pub const cloneRow = core.cloneRow;
pub const deinitOwnedRow = core.deinitOwnedRow;
pub const Storage = core.Storage;

pub fn assertCodec(comptime T: type) void {
    if (@typeInfo(T) != .@"enum") @compileError(
        "sqlz codec '" ++ @typeName(T) ++
            "' is not supported yet: only Zig enums are derived in this slice",
    );
}

pub const sqlite = if (options.sqlite)
    @import("sqlz_sqlite").sqlite
else
    struct {};
pub const Blob = if (options.sqlite) @import("sqlz_sqlite").Blob else struct { value: []const u8 };
pub const blob = if (options.sqlite) @import("sqlz_sqlite").blob else struct {
    fn unavailable(_: []const u8) Blob {
        @compileError("sqlz.Blob requires the SQLite runtime adapter");
    }
}.unavailable;

pub const postgres = if (options.postgres)
    @import("sqlz_postgres").postgres
else
    struct {};
