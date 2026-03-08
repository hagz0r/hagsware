const dumper = @import("dumper/mod.zig");

pub const AppContext = struct {
    db: *dumper.Database,
};
