const AppContext = @import("../app_context.zig").AppContext;
const log = @import("../log.zig");
const signatures = @import("../signatures/mod.zig");
const mem = @import("../utils/memory.zig");
const Vec3 = @import("../utils/types.zig").Vec3;

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
const summary_log_interval_ticks: usize = 40;

pub const HackImpl = struct {
    app: *AppContext,

    dw_local_player_pawn: usize = 0,
    dw_network_game_client: usize = 0,
    dw_network_game_client_max_clients: usize = 0,

    m_h_player_pawn: usize = 0,
    m_h_pawn: usize = 0,
    m_i_health: usize = 0,
    m_i_team_num: usize = 0,
    m_life_state: usize = 0,
    m_v_old_origin: usize = 0,

    entity_system_pointer_addr: usize = 0,
    entity_list_offset: usize = 0,

    tick: usize = 0,

    pub fn init(self: *HackImpl) !void {
        self.dw_local_player_pawn = self.app.db.offsets.dw_local_player_pawn;
        self.dw_network_game_client = self.app.db.offsets.dw_network_game_client;
        self.dw_network_game_client_max_clients = self.app.db.offsets.dw_network_game_client_max_clients;

        self.m_h_player_pawn = self.app.db.client.m_h_player_pawn;
        self.m_h_pawn = self.app.db.client.m_h_pawn;
        self.m_i_health = self.app.db.client.m_i_health;
        self.m_i_team_num = self.app.db.client.m_i_team_num;
        self.m_life_state = self.app.db.client.m_life_state;
        self.m_v_old_origin = self.app.db.client.m_v_old_origin;

        try resolvePatterns(self);

        log.info("ESP init done", .{});
    }

    pub fn update(self: *HackImpl) !void {
        self.tick += 1;
        const log_positions = self.tick % summary_log_interval_ticks == 0;

        const ngc = mem.read(usize, self.app.game.engine2_base + self.dw_network_game_client) orelse return;
        const max_clients = mem.read(i32, ngc + self.dw_network_game_client_max_clients) orelse return;
        if (max_clients <= 0 or max_clients > max_reasonable_clients) return;

        const entity_list = getEntityList(self) orelse return;

        const local_pawn = mem.read(usize, self.app.game.client_base + self.dw_local_player_pawn) orelse 0;
        const local_team: u8 = if (local_pawn != 0) (mem.read(u8, local_pawn + self.m_i_team_num) orelse 0) else 0;

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

            total_players += 1;
            if (local_team != 0 and team != local_team) enemy_players += 1;

            if (log_positions) {
                log.info(
                    "ESP player: slot={d}, team={d}, hp={d}, pos=({},{},{})",
                    .{ slot, team, health, origin.x, origin.y, origin.z },
                );
            }
        }

        if (log_positions) {
            log.info("ESP players: total={d}, enemies={d}", .{ total_players, enemy_players });
            log.info(
                "ESP pipeline: ctrl={d}, handle={d}, pawn={d}, hp={d}, life={d}, team={d}, origin={d}",
                .{ controllers_found, handles_found, pawns_found, health_ok, life_ok, team_ok, origin_ok },
            );
        }
    }
};

fn getPawnOrigin(self: *const HackImpl, pawn: usize) ?Vec3 {
    const origin = mem.read(Vec3, pawn + self.m_v_old_origin) orelse return null;
    if (origin.x == 0 and origin.y == 0 and origin.z == 0) return null;
    return origin;
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
