const std = @import("std");
const AppContext = @import("../app_context.zig").AppContext;
const config = @import("../config.zig");
const log = @import("../log.zig");
const render = @import("../render/mod.zig");
const mem = @import("../utils/memory.zig");
const entity_system = @import("../game/entity_system.zig");
const entity_list = @import("../game/entity_list.zig");
const projection = @import("../math/projection.zig");
const player = @import("../game/player.zig");
const Vec3 = @import("../utils/types.zig").Vec3;

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

    tick: usize = 0,
    cache_mutex: std.Thread.Mutex = .{},
    cached_players: [max_cached_players]CachedPlayer = undefined,
    cached_count: usize = 0,
    cached_local_team: u8 = 0,
    cache_timestamp_ns: i128 = 0,

    pub fn init(self: *HackImpl) !void {
        try entity_system.init();

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

        const ngc = player.readNetworkGameClient(self.app) orelse {
            clearCache(self);
            return;
        };
        const max_clients = player.readMaxClients(self.app, ngc) orelse {
            clearCache(self);
            return;
        };
        if (max_clients <= 0 or max_clients > max_reasonable_clients) {
            clearCache(self);
            return;
        }

        const entity_list_ptr = entity_system.getEntityList() orelse {
            clearCache(self);
            return;
        };

        const schema = &self.app.db.client;
        const local_pawn = player.readLocalPawn(self.app);
        const local_team = player.readTeamAtPawn(local_pawn, schema);

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
            const controller = entity_list.getEntityByIndex(entity_list_ptr, slot) orelse continue;
            controllers_found += 1;

            const pawn_handle = player.readPawnHandle(controller, schema) orelse continue;
            handles_found += 1;

            const pawn = entity_list.getEntityByHandle(entity_list_ptr, pawn_handle) orelse continue;
            pawns_found += 1;

            if (pawn == local_pawn) continue;

            const health = mem.read(i32, pawn + schema.m_i_health) orelse continue;
            if (health <= 0 or health > 100) continue;
            health_ok += 1;

            const life_state = mem.read(u8, pawn + schema.m_life_state) orelse continue;
            if (life_state != 0) continue;
            life_ok += 1;

            const team = mem.read(u8, pawn + schema.m_i_team_num) orelse continue;
            if (team < 2 or team > 3) continue;
            team_ok += 1;

            const origin = player.readPawnOrigin(pawn, schema) orelse continue;
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

        const view_matrix = player.readViewMatrix(self.app) orelse return;
        const window = player.readWindowSize(self.app) orelse return;

        if (cfg.draw_center_cross) {
            render.pushCross(
                .{
                    .x = window.width * 0.5,
                    .y = window.height * 0.5,
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
            const cached = snapshot[i];
            const feet_screen = projection.worldToScreen(cached.origin, view_matrix, window.width, window.height) orelse continue;

            const head_origin = Vec3{
                .x = cached.origin.x,
                .y = cached.origin.y,
                .z = cached.origin.z + 72.0,
            };
            const head_screen = projection.worldToScreen(head_origin, view_matrix, window.width, window.height) orelse {
                const color_fallback = if (local_team != 0 and cached.team != local_team) cfg.enemy_color else cfg.friendly_color;
                render.pushCross(feet_screen, 3, color_fallback);
                continue;
            };

            const color = if (local_team != 0 and cached.team != local_team) cfg.enemy_color else cfg.friendly_color;
            const top = @min(head_screen.y, feet_screen.y);
            const bottom = @max(head_screen.y, feet_screen.y);
            const box_h = bottom - top;
            const box_w = box_h * 0.45;

            if (cfg.draw_box and box_h > 4.0 and box_w > 2.0) {
                render.pushBox(
                    feet_screen.x - box_w * 0.5,
                    top,
                    feet_screen.x + box_w * 0.5,
                    bottom,
                    cfg.box_thickness,
                    color,
                );
            } else {
                render.pushCross(feet_screen, 3, color);
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
