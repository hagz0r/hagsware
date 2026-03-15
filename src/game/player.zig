const AppContext = @import("../app_context.zig").AppContext;
const dumper = @import("../dumper/mod.zig");
const mem = @import("../utils/memory.zig");
const Vec3 = @import("../utils/types.zig").Vec3;
const Mat4x4 = @import("../math/projection.zig").Mat4x4;

pub const WindowSize = struct {
    width: f32,
    height: f32,
};

pub fn readNetworkGameClient(app: *const AppContext) ?usize {
    return mem.read(usize, app.game.engine2_base + app.db.offsets.dw_network_game_client);
}

pub fn readMaxClients(app: *const AppContext, ngc: usize) ?i32 {
    return mem.read(i32, ngc + app.db.offsets.dw_network_game_client_max_clients);
}

pub fn readLocalPawn(app: *const AppContext) usize {
    return mem.read(usize, app.game.client_base + app.db.offsets.dw_local_player_pawn) orelse 0;
}

pub fn readTeamAtPawn(pawn: usize, schema: *const dumper.SchemaTable) u8 {
    if (pawn == 0) return 0;
    return mem.read(u8, pawn + schema.m_i_team_num) orelse 0;
}

pub fn readPawnHandle(controller: usize, schema: *const dumper.SchemaTable) ?u32 {
    var pawn_handle = mem.read(u32, controller + schema.m_h_player_pawn) orelse 0;
    if (pawn_handle == 0) pawn_handle = mem.read(u32, controller + schema.m_h_pawn) orelse 0;
    if (pawn_handle == 0) return null;
    return pawn_handle;
}

pub fn readPawnOrigin(pawn: usize, schema: *const dumper.SchemaTable) ?Vec3 {
    const origin = mem.read(Vec3, pawn + schema.m_v_old_origin) orelse return null;
    if (origin.x == 0 and origin.y == 0 and origin.z == 0) return null;
    return origin;
}

pub fn readViewMatrix(app: *const AppContext) ?Mat4x4 {
    return mem.read(Mat4x4, app.game.client_base + app.db.offsets.dw_view_matrix);
}

pub fn readWindowSize(app: *const AppContext) ?WindowSize {
    const width = mem.read(i32, app.game.engine2_base + app.db.offsets.dw_window_width) orelse return null;
    const height = mem.read(i32, app.game.engine2_base + app.db.offsets.dw_window_height) orelse return null;
    if (width <= 0 or height <= 0) return null;
    return .{
        .width = @floatFromInt(width),
        .height = @floatFromInt(height),
    };
}
