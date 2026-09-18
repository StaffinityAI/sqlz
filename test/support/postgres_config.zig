pub const Config = struct {
    host: []const u8,
    port: u16,
    database: []const u8,
    username: []const u8,
    password: []const u8,
    expected_major: u16,

    pub fn validate(self: Config) error{ InvalidPort, UnsupportedMajor }!void {
        if (self.port == 0) return error.InvalidPort;
        if (self.expected_major < 15 or self.expected_major > 18)
            return error.UnsupportedMajor;
    }
};
