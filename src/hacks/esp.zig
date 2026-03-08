const AppContext = @import("../app_context.zig").AppContext;
const log = @import("../log.zig");

pub const HackImpl = struct {
    app: *AppContext,
    entity_list_addr: usize = 0,

    pub fn init(self: *HackImpl) !void {
        const dw_entity_list_offset = try self.app.db.offsets.get("client.dll", "dwEntityList");
        self.entity_list_addr = self.app.game.client_base + dw_entity_list_offset;
        log.info("ESP init: dwEntityList @ 0x{x}", .{self.entity_list_addr});
    }

    pub fn update(self: *HackImpl) !void {
        _ = self;
    }
};
