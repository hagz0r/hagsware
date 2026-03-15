const hacks_mod = @import("../hacks.zig");
const log = @import("../log.zig");
const mem = @import("memory.zig");

pub const Vec3 = @import("types.zig").Vec3;

pub const Entity = struct {
    name: []const u8,
    origin: Vec3,
};

var scene_state_known = false;
var last_scene_loaded = false;
var scene_probe_count: usize = 0;

pub fn isSceneLoaded(registry: hacks_mod.Registry) !bool {
    const dw_ngc = registry.app.db.offsets.dw_network_game_client;
    const off_signon = registry.app.db.offsets.dw_network_game_client_sign_on_state;
    const off_max_clients = registry.app.db.offsets.dw_network_game_client_max_clients;
    const dw_local_pawn = registry.app.db.offsets.dw_local_player_pawn;

    const ngc = mem.read(usize, registry.app.game.engine2_base + dw_ngc) orelse 0;
    var sign_on_state: i32 = -1;
    var max_clients: i32 = 0;
    if (ngc != 0) {
        sign_on_state = mem.read(i32, ngc + off_signon) orelse -1;
        max_clients = mem.read(i32, ngc + off_max_clients) orelse 0;
    }

    const local_pawn = mem.read(usize, registry.app.game.client_base + dw_local_pawn) orelse 0;
    const loaded = ngc != 0 and sign_on_state == 6 and max_clients > 0 and local_pawn != 0;

    scene_probe_count += 1;
    if (!scene_state_known or loaded != last_scene_loaded) {
        log.info("Scene state changed: loaded={any}, sign_on={d}, max_clients={d}, ngc=0x{x}, local_pawn=0x{x}", .{ loaded, sign_on_state, max_clients, ngc, local_pawn });
        scene_state_known = true;
        last_scene_loaded = loaded;
    } else if (!loaded and scene_probe_count % 200 == 0) {
        log.info("Scene wait: sign_on={d}, max_clients={d}, ngc=0x{x}, local_pawn=0x{x}", .{ sign_on_state, max_clients, ngc, local_pawn });
    }

    return loaded;
}

const kb = @import("win32").ui.input.keyboard_and_mouse;
pub fn panicPressed() bool {
    return kb.GetAsyncKeyState(@as(i32, @intFromEnum(kb.VK_END))) < 0;
}
