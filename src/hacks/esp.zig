const std = @import("std");
const AppContext = @import("../app_context.zig").AppContext;
const log = @import("../log.zig");
const signatures = @import("../signatures/mod.zig");
const mem = @import("../utils/memory.zig");
const Vec3 = @import("../utils/types.zig").Vec3;

const GetAbsOriginFn = fn (entity: *anyopaque) callconv(.c) ?*const Vec3;

const sig_entity_system_pointer = signatures.ModuleInfo{
    .name = "client.dll",
    .signature = "48 89 ? ? ? ? ? 4C 63 ? ? ? ? ? 44 3B ? ? ? ? ? 0F",
};
const sig_entity_list_offset = signatures.ModuleInfo{
    .name = "client.dll",
    .signature = "48 8D ? ? E8 ? ? ? ? 8D 85",
};
const sig_get_abs_origin = signatures.ModuleInfo{
    .name = "client.dll",
    .signature = "F8 ? 75 ? E8 ? ? ? ? F3",
};

const entity_list_chunk_start: usize = 0x10;
const entity_list_chunk_stride: usize = 0x8;
const entity_identity_stride: usize = 0x70;
const entity_identity_entity_offset: usize = 0x0;
const entity_identity_handle_offset: usize = 0x10;
const entity_page_mask: u32 = 0x1FF;
const entity_index_mask: u32 = 0x7FFF;
const max_reasonable_clients: i32 = 64;
const pattern_retry_interval_ticks: usize = 200;
const summary_log_interval_ticks: usize = 40;

pub const HackImpl = struct {
    app: *AppContext,

    dw_entity_list: usize = 0,
    dw_local_player_pawn: usize = 0,
    dw_network_game_client: usize = 0,
    dw_network_game_client_max_clients: usize = 0,

    m_h_player_pawn: usize = 0,
    m_h_pawn: usize = 0,
    m_i_health: usize = 0,
    m_i_team_num: usize = 0,
    m_life_state: usize = 0,
    m_v_old_origin: usize = 0,
    m_p_game_scene_node: usize = 0,
    m_vec_abs_origin: usize = 0,

    entity_system_pointer_addr: usize = 0,
    entity_list_offset: isize = 0,
    get_abs_origin_fn: ?*const GetAbsOriginFn = null,
    patterns_ready: bool = false,
    pattern_resolve_attempts: usize = 0,

    tick: usize = 0,

    pub fn init(self: *HackImpl) !void {
        self.dw_entity_list = try self.app.db.offsets.get("client.dll", "dwEntityList");
        self.dw_local_player_pawn = try self.app.db.offsets.get("client.dll", "dwLocalPlayerPawn");
        self.dw_network_game_client = try self.app.db.offsets.get("engine2.dll", "dwNetworkGameClient");
        self.dw_network_game_client_max_clients = try self.app.db.offsets.get("engine2.dll", "dwNetworkGameClient_maxClients");

        self.m_h_player_pawn = try self.app.db.client.field("CCSPlayerController", "m_hPlayerPawn");
        self.m_h_pawn = try self.app.db.client.field("CBasePlayerController", "m_hPawn");
        self.m_i_health = try self.app.db.client.field("C_BaseEntity", "m_iHealth");
        self.m_i_team_num = try self.app.db.client.field("C_BaseEntity", "m_iTeamNum");
        self.m_life_state = try self.app.db.client.field("C_BaseEntity", "m_lifeState");
        self.m_v_old_origin = try self.app.db.client.field("C_BasePlayerPawn", "m_vOldOrigin");
        self.m_p_game_scene_node = try self.app.db.client.field("C_BaseEntity", "m_pGameSceneNode");
        self.m_vec_abs_origin = try self.app.db.client.field("CGameSceneNode", "m_vecAbsOrigin");

        tryResolvePatterns(self);
        if (!self.patterns_ready) {
            log.info("ESP init: signatures not ready, fallback=dwEntityList", .{});
        }

        log.info("ESP init done", .{});
    }

    pub fn update(self: *HackImpl) !void {
        self.tick += 1;
        if (!self.patterns_ready and self.tick % pattern_retry_interval_ticks == 0) {
            tryResolvePatterns(self);
        }

        const ngc = mem.read(usize, self.app.game.engine2_base + self.dw_network_game_client) orelse return;
        const max_clients = mem.read(i32, ngc + self.dw_network_game_client_max_clients) orelse return;
        if (max_clients <= 0 or max_clients > max_reasonable_clients) return;

        const entity_list = getEntityList(self) orelse return;

        const local_pawn = mem.read(usize, self.app.game.client_base + self.dw_local_player_pawn) orelse 0;
        const local_team: u8 = if (local_pawn != 0) (mem.read(u8, local_pawn + self.m_i_team_num) orelse 0) else 0;

        var total_players: usize = 0;
        var enemy_players: usize = 0;

        const slot_limit: u32 = @intCast(max_clients);
        var slot: u32 = 1;
        while (slot <= slot_limit) : (slot += 1) {
            const controller = getEntityByIndex(entity_list, slot) orelse continue;

            var pawn_handle = mem.read(u32, controller + self.m_h_player_pawn) orelse 0;
            if (pawn_handle == 0) pawn_handle = mem.read(u32, controller + self.m_h_pawn) orelse 0;
            if (pawn_handle == 0) continue;

            const pawn = getEntityByHandle(entity_list, pawn_handle) orelse continue;
            if (pawn == local_pawn) continue;

            const health = mem.read(i32, pawn + self.m_i_health) orelse continue;
            if (health <= 0 or health > 100) continue;

            const life_state = mem.read(u8, pawn + self.m_life_state) orelse continue;
            if (life_state != 0) continue;

            const team = mem.read(u8, pawn + self.m_i_team_num) orelse continue;
            if (team < 2 or team > 3) continue;

            _ = getPawnOrigin(self, pawn) orelse continue;

            total_players += 1;
            if (local_team != 0 and team != local_team) enemy_players += 1;
        }

        if (self.tick % summary_log_interval_ticks == 0) {
            log.info("ESP players: total={d}, enemies={d}", .{ total_players, enemy_players });
        }
    }
};

fn getPawnOrigin(self: *const HackImpl, pawn: usize) ?Vec3 {
    if (self.get_abs_origin_fn) |get_abs_origin| {
        const pawn_ptr = @as(*anyopaque, @ptrFromInt(pawn));
        if (get_abs_origin(pawn_ptr)) |abs_origin_ptr| {
            const abs_origin = abs_origin_ptr.*;
            if (abs_origin.x != 0 or abs_origin.y != 0 or abs_origin.z != 0) {
                return abs_origin;
            }
        }
    }

    if (mem.read(Vec3, pawn + self.m_v_old_origin)) |old_origin| {
        if (old_origin.x != 0 or old_origin.y != 0 or old_origin.z != 0) return old_origin;
    }

    const scene_node = mem.read(usize, pawn + self.m_p_game_scene_node) orelse return null;
    return mem.read(Vec3, scene_node + self.m_vec_abs_origin);
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
    if (self.patterns_ready) {
        const entity_system = mem.read(usize, self.entity_system_pointer_addr) orelse 0;
        if (entity_system != 0) {
            const entity_list_addr = addSignedOffset(entity_system, self.entity_list_offset) orelse 0;
            if (entity_list_addr != 0) {
                const entity_list = mem.read(usize, entity_list_addr) orelse 0;
                if (entity_list != 0) return entity_list;
            }
        }
    }

    const fallback_entity_list = mem.read(usize, self.app.game.client_base + self.dw_entity_list) orelse return null;
    if (fallback_entity_list == 0) return null;
    return fallback_entity_list;
}

fn tryResolvePatterns(self: *HackImpl) void {
    self.pattern_resolve_attempts += 1;

    const entity_system_pointer_addr = signatures.resolveModuleAbs(sig_entity_system_pointer, 3, 4) orelse {
        logPatternResolveFailure(self);
        return;
    };
    const entity_list_offset = resolveEntityListOffset() orelse {
        logPatternResolveFailure(self);
        return;
    };
    const get_abs_origin_addr = signatures.resolveModuleAbs(sig_get_abs_origin, 5, 4) orelse {
        logPatternResolveFailure(self);
        return;
    };

    self.entity_system_pointer_addr = entity_system_pointer_addr;
    self.entity_list_offset = entity_list_offset;
    self.get_abs_origin_fn = @as(*const GetAbsOriginFn, @ptrFromInt(get_abs_origin_addr));
    self.patterns_ready = true;

    log.info(
        "ESP signatures ready: entity_system_ptr=0x{x}, entity_list_offset=0x{x}, get_abs_origin=0x{x}",
        .{
            self.entity_system_pointer_addr,
            @as(usize, @intCast(self.entity_list_offset)),
            get_abs_origin_addr,
        },
    );
}

fn resolveEntityListOffset() ?isize {
    if (signatures.resolveModuleRead(i8, sig_entity_list_offset, 3)) |offset8| {
        if (offset8 > 0) return @as(isize, offset8);
    }

    if (signatures.resolveModuleRead(i32, sig_entity_list_offset, 3)) |offset32| {
        if (offset32 > 0 and offset32 < 0x1000) return @as(isize, offset32);
    }

    return null;
}

fn logPatternResolveFailure(self: *const HackImpl) void {
    if (self.pattern_resolve_attempts == 1 or self.pattern_resolve_attempts % 10 == 0) {
        log.info("ESP signatures pending: attempt={d}", .{self.pattern_resolve_attempts});
    }
}

fn addSignedOffset(base: usize, offset: isize) ?usize {
    const signed_base = std.math.cast(isize, base) orelse return null;
    const signed_result = std.math.add(isize, signed_base, offset) catch return null;
    return std.math.cast(usize, signed_result);
}
