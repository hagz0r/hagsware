// Get 3D Positions of players
// Convert to 2D screen coordinates
// Draw ESP boxes on the screen
const std = @import("std");
const AppContext = @import("../app_context.zig").AppContext;
const dumper = @import("../dumper/mod.zig");
const log = @import("../log.zig");
const u = @import("../utils/mod.zig");

pub const HackImpl = struct {
    app: *AppContext,

    pub fn init(_: *HackImpl) !void {}

    pub fn update(_: *HackImpl) !void {}
};

pub const EspHack = HackImpl;
