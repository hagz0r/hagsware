const std = @import("std");
const AppContext = @import("../app_context.zig").AppContext;
const config = @import("../config.zig");
const log = @import("../log.zig");
const render = @import("../render/mod.zig");
const signatures = @import("../signatures/mod.zig");
const mem = @import("../utils/memory.zig");
const entity_list = @import("../game/entity_list.zig");
const projection = @import("../math/projection.zig");
const player = @import("../game/player.zig");
const Vec3 = @import("../utils/types.zig").Vec3;

pub const HackImpl = struct {
    app: *AppContext,
    pub fn init(self: *HackImpl) !void {
        _ = self;
    }
    pub fn update(self: *HackImpl) !void {
        _ = self;
    }
};
