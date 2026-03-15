const std = @import("std");
const AppContext = @import("../app_context.zig").AppContext;
const config = @import("../config.zig");
const log = @import("../log.zig");
const render = @import("../render/mod.zig");
const signatures = @import("../signatures/mod.zig");
const mem = @import("../utils/memory.zig");
const Vec2 = @import("../utils/types.zig").Vec2;
const Vec3 = @import("../utils/types.zig").Vec3;
const Mat4x4 = [4][4]f32;

const sig_entity_system_pointer = signatures.ModuleInfo{
    .name = "client.dll",
    .signature = "48 89 ? ? ? ? ? 4C 63 ? ? ? ? ? 44 3B ? ? ? ? ? 0F",
};
const sig_entity_list_offset = signatures.ModuleInfo{
    .name = "client.dll",
    .signature = "48 8D ? ? E8 ? ? ? ? 8D 85",
};

const entity_list_chunk_start: usize = 0x0;
const entity_list_chunk_stride: usize = 0x8;
const entity_identity_stride: usize = 0x70;
const entity_identity_entity_offset: usize = 0x0;
const entity_identity_handle_offset: usize = 0x10;
const entity_page_mask: u32 = 0x1FF;
const entity_index_mask: u32 = 0x7FFF;
const max_reasonable_clients: i32 = 64;
const max_cached_players: usize = max_reasonable_clients;
const max_cache_age_ns: i128 = 200_000_000;
const summary_log_interval_ticks: usize = 256;

const CachedPlayer = struct {
    slot: u32,
    team: u8,
    health: i32,
    origin: Vec3,
};

pub const HackImpl = struct {
    app: *AppContext,

    dw_local_player_pawn: usize = 0,
    dw_network_game_client: usize = 0,
    dw_network_game_client_max_clients: usize = 0,
    dw_view_matrix: usize = 0,
    dw_window_width: usize = 0,
    dw_window_height: usize = 0,

    m_h_player_pawn: usize = 0,
    m_h_pawn: usize = 0,
    m_i_health: usize = 0,
    m_i_team_num: usize = 0,
    m_life_state: usize = 0,
    m_v_old_origin: usize = 0,

    entity_system_pointer_addr: usize = 0,
    entity_list_offset: usize = 0,

    tick: usize = 0,
    cache_mutex: std.Thread.Mutex = .{},
    cached_players: [max_cached_players]CachedPlayer = undefined,
    cached_count: usize = 0,
    cached_local_team: u8 = 0,
    cache_timestamp_ns: i128 = 0,

    pub fn init(self: *HackImpl) !void {
        self.dw_local_player_pawn = self.app.db.offsets.dw_local_player_pawn;
        self.dw_network_game_client = self.app.db.offsets.dw_network_game_client;
        self.dw_network_game_client_max_clients = self.app.db.offsets.dw_network_game_client_max_clients;
        self.dw_view_matrix = self.app.db.offsets.dw_view_matrix;
        self.dw_window_width = self.app.db.offsets.dw_window_width;
        self.dw_window_height = self.app.db.offsets.dw_window_height;

        self.m_h_player_pawn = self.app.db.client.m_h_player_pawn;
        self.m_h_pawn = self.app.db.client.m_h_pawn;
        self.m_i_health = self.app.db.client.m_i_health;
        self.m_i_team_num = self.app.db.client.m_i_team_num;
        self.m_life_state = self.app.db.client.m_life_state;
        self.m_v_old_origin = self.app.db.client.m_v_old_origin;

        try resolvePatterns(self);

        active_instance = self;
        render.setFrameCallback(frameCallback);
        log.info("ESP init done", .{});
    }

    pub fn update(self: *HackImpl) !void {
        self.tick += 1;
        const log_positions = self.tick % summary_log_interval_ticks == 0;
        const cfg = config.get().esp;
        if (!cfg.enabled) {
            clearCache(self);
            return;
        }

        const ngc = mem.read(usize, self.app.game.engine2_base + self.dw_network_game_client) orelse {
            clearCache(self);
            return;
        };
        const max_clients = mem.read(i32, ngc + self.dw_network_game_client_max_clients) orelse {
            clearCache(self);
            return;
        };
        if (max_clients <= 0 or max_clients > max_reasonable_clients) {
            clearCache(self);
            return;
        }

        const entity_list = getEntityList(self) orelse {
            clearCache(self);
            return;
        };

        const local_pawn = mem.read(usize, self.app.game.client_base + self.dw_local_player_pawn) orelse 0;
        const local_team: u8 = if (local_pawn != 0) (mem.read(u8, local_pawn + self.m_i_team_num) orelse 0) else 0;

        var next_players: [max_cached_players]CachedPlayer = undefined;
        var next_count: usize = 0;

        var total_players: usize = 0;
        var enemy_players: usize = 0;
        var controllers_found: usize = 0;
        var handles_found: usize = 0;
        var pawns_found: usize = 0;
        var health_ok: usize = 0;
        var life_ok: usize = 0;
        var team_ok: usize = 0;
        var origin_ok: usize = 0;

        const slot_limit: u32 = @intCast(max_clients);
        var slot: u32 = 1;
        while (slot <= slot_limit) : (slot += 1) {
            const controller = getEntityByIndex(entity_list, slot) orelse continue;
            controllers_found += 1;

            var pawn_handle = mem.read(u32, controller + self.m_h_player_pawn) orelse 0;
            if (pawn_handle == 0) pawn_handle = mem.read(u32, controller + self.m_h_pawn) orelse 0;
            if (pawn_handle == 0) continue;
            handles_found += 1;

            const pawn = getEntityByHandle(entity_list, pawn_handle) orelse continue;
            pawns_found += 1;

            if (pawn == local_pawn) continue;

            const health = mem.read(i32, pawn + self.m_i_health) orelse continue;
            if (health <= 0 or health > 100) continue;
            health_ok += 1;

            const life_state = mem.read(u8, pawn + self.m_life_state) orelse continue;
            if (life_state != 0) continue;
            life_ok += 1;

            const team = mem.read(u8, pawn + self.m_i_team_num) orelse continue;
            if (team < 2 or team > 3) continue;
            team_ok += 1;

            const origin = getPawnOrigin(self, pawn) orelse continue;
            origin_ok += 1;

            if (next_count < max_cached_players) {
                next_players[next_count] = .{
                    .slot = slot,
                    .team = team,
                    .health = health,
                    .origin = origin,
                };
                next_count += 1;
            }

            const is_enemy = local_team != 0 and team != local_team;
            total_players += 1;
            if (is_enemy) enemy_players += 1;

            if (log_positions) {
                log.info(
                    "ESP player: slot={d}, team={d}, hp={d}, world=({},{},{})",
                    .{ slot, team, health, origin.x, origin.y, origin.z },
                );
            }
        }

        self.cache_mutex.lock();
        self.cached_count = next_count;
        self.cached_local_team = local_team;
        self.cache_timestamp_ns = std.time.nanoTimestamp();
        if (next_count > 0) {
            std.mem.copyForwards(CachedPlayer, self.cached_players[0..next_count], next_players[0..next_count]);
        }
        self.cache_mutex.unlock();

        if (log_positions) {
            log.info("ESP players: total={d}, enemies={d}", .{ total_players, enemy_players });
            log.info(
                "ESP pipeline: ctrl={d}, handle={d}, pawn={d}, hp={d}, life={d}, team={d}, origin={d}",
                .{ controllers_found, handles_found, pawns_found, health_ok, life_ok, team_ok, origin_ok },
            );
        }
    }

    fn renderFrame(self: *HackImpl) void {
        const cfg = config.get().esp;
        config.warnTextSettingsIfNeeded();

        render.beginCommands();
        defer render.endCommands();

        if (!cfg.enabled) return;

        const view_matrix = mem.read(Mat4x4, self.app.game.client_base + self.dw_view_matrix) orelse return;
        const window_width = mem.read(i32, self.app.game.engine2_base + self.dw_window_width) orelse return;
        const window_height = mem.read(i32, self.app.game.engine2_base + self.dw_window_height) orelse return;
        if (window_width <= 0 or window_height <= 0) return;
        const screen_width: f32 = @floatFromInt(window_width);
        const screen_height: f32 = @floatFromInt(window_height);

        if (cfg.draw_center_cross) {
            render.pushCross(
                .{
                    .x = screen_width * 0.5,
                    .y = screen_height * 0.5,
                },
                5,
                cfg.debug_color,
            );
        }

        var snapshot: [max_cached_players]CachedPlayer = undefined;
        var snapshot_count: usize = 0;
        var local_team: u8 = 0;
        var cache_timestamp_ns: i128 = 0;

        self.cache_mutex.lock();
        snapshot_count = self.cached_count;
        local_team = self.cached_local_team;
        cache_timestamp_ns = self.cache_timestamp_ns;
        if (snapshot_count > 0) {
            std.mem.copyForwards(CachedPlayer, snapshot[0..snapshot_count], self.cached_players[0..snapshot_count]);
        }
        self.cache_mutex.unlock();

        const now_ns = std.time.nanoTimestamp();
        if (cache_timestamp_ns == 0 or now_ns - cache_timestamp_ns > max_cache_age_ns) return;

        var i: usize = 0;
        while (i < snapshot_count) : (i += 1) {
            const player = snapshot[i];
            const screen = worldToScreen(player.origin, view_matrix, screen_width, screen_height) orelse continue;

            const head_origin = Vec3{
                .x = player.origin.x,
                .y = player.origin.y,
                .z = player.origin.z + 72.0,
            };
            const head_screen = worldToScreen(head_origin, view_matrix, screen_width, screen_height) orelse {
                const color_fallback = if (local_team != 0 and player.team != local_team) cfg.enemy_color else cfg.friendly_color;
                render.pushCross(screen, 3, color_fallback);
                continue;
            };

            const color = if (local_team != 0 and player.team != local_team) cfg.enemy_color else cfg.friendly_color;
            const top = @min(head_screen.y, screen.y);
            const bottom = @max(head_screen.y, screen.y);
            const box_h = bottom - top;
            const box_w = box_h * 0.45;

            if (cfg.draw_box and box_h > 4.0 and box_w > 2.0) {
                render.pushBox(
                    screen.x - box_w * 0.5,
                    top,
                    screen.x + box_w * 0.5,
                    bottom,
                    cfg.box_thickness,
                    color,
                );
            } else {
                render.pushCross(screen, 3, color);
            }
        }
    }
};

var active_instance: ?*HackImpl = null;

fn frameCallback() void {
    const self = active_instance orelse return;
    self.renderFrame();
}

fn clearCache(self: *HackImpl) void {
    self.cache_mutex.lock();
    self.cached_count = 0;
    self.cached_local_team = 0;
    self.cache_timestamp_ns = 0;
    self.cache_mutex.unlock();
}

fn getPawnOrigin(self: *const HackImpl, pawn: usize) ?Vec3 {
    const origin = mem.read(Vec3, pawn + self.m_v_old_origin) orelse return null;
    if (origin.x == 0 and origin.y == 0 and origin.z == 0) return null;
    return origin;
}

fn worldToScreen(origin: Vec3, matrix: Mat4x4, screen_width: f32, screen_height: f32) ?Vec2 {
    const clip_x =
        matrix[0][0] * origin.x +
        matrix[0][1] * origin.y +
        matrix[0][2] * origin.z +
        matrix[0][3];
    const clip_y =
        matrix[1][0] * origin.x +
        matrix[1][1] * origin.y +
        matrix[1][2] * origin.z +
        matrix[1][3];
    const clip_w =
        matrix[3][0] * origin.x +
        matrix[3][1] * origin.y +
        matrix[3][2] * origin.z +
        matrix[3][3];
    if (clip_w <= 0.001) return null;

    const inv_w: f32 = 1.0 / clip_w;
    const ndc_x = clip_x * inv_w;
    const ndc_y = clip_y * inv_w;
    if (ndc_x < -1.0 or ndc_x > 1.0 or ndc_y < -1.0 or ndc_y > 1.0) return null;

    return .{
        .x = (screen_width * 0.5) * (ndc_x + 1.0),
        .y = (screen_height * 0.5) * (1.0 - ndc_y),
    };
}

fn getEntityByHandle(entity_list: usize, handle: u32) ?usize {
    const index = handle & entity_index_mask;
    if (index == 0) return null;

    const identity = getEntityIdentity(entity_list, index) orelse return null;
    const identity_handle = mem.read(u32, identity + entity_identity_handle_offset) orelse return null;
    if (identity_handle != handle) return null;

    const entity = mem.read(usize, identity + entity_identity_entity_offset) orelse return null;
    if (entity == 0) return null;
    return entity;
}

fn getEntityByIndex(entity_list: usize, index: u32) ?usize {
    const identity = getEntityIdentity(entity_list, index) orelse return null;
    const entity = mem.read(usize, identity + entity_identity_entity_offset) orelse return null;
    if (entity == 0) return null;
    return entity;
}

fn getEntityIdentity(entity_list: usize, index: u32) ?usize {
    const chunk_index = index >> 9;
    const chunk_addr = entity_list + entity_list_chunk_start + entity_list_chunk_stride * chunk_index;
    const chunk = mem.read(usize, chunk_addr) orelse return null;
    if (chunk == 0) return null;

    const entity_index_in_page = index & entity_page_mask;
    return chunk + entity_identity_stride * entity_index_in_page;
}

fn getEntityList(self: *const HackImpl) ?usize {
    if (self.entity_system_pointer_addr == 0 or self.entity_list_offset == 0) return null;

    const entity_system = mem.read(usize, self.entity_system_pointer_addr) orelse return null;
    if (entity_system == 0) return null;

    return entity_system + self.entity_list_offset;
}

fn resolvePatterns(self: *HackImpl) !void {
    const entity_system_pattern = signatures.resolveModule(sig_entity_system_pointer) orelse {
        return error.EntitySystemPointerPatternNotFound;
    };
    const entity_system_disp_addr = @intFromPtr(entity_system_pattern) + 3;
    self.entity_system_pointer_addr = signatures.readRelativeAddress(entity_system_disp_addr, 4) orelse {
        return error.EntitySystemPointerResolveFailed;
    };

    self.entity_list_offset = resolveEntityListOffset() orelse {
        return error.EntityListOffsetPatternNotFound;
    };

    log.info(
        "ESP signatures ready: ent_sys_pat=0x{x}, ent_sys_ptr=0x{x}, ent_list_off=0x{x}",
        .{
            @intFromPtr(entity_system_pattern),
            self.entity_system_pointer_addr,
            self.entity_list_offset,
        },
    );
}

fn resolveEntityListOffset() ?usize {
    if (signatures.resolveModuleRead(i8, sig_entity_list_offset, 3)) |offset8| {
        if (offset8 > 0) return @as(usize, @intCast(offset8));
    }

    return null;
}
