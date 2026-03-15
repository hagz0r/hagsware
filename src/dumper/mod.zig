const std = @import("std");

const offsets = @import("offsets.zig").cs2_dumper.offsets;
const client_schema = @import("client_dll.zig").cs2_dumper.schemas.client_dll;

pub const OffsetTable = struct {
    dw_entity_list: usize,
    dw_local_player_pawn: usize,
    dw_network_game_client: usize,
    dw_network_game_client_max_clients: usize,
    dw_network_game_client_sign_on_state: usize,
    dw_view_matrix: usize,
    dw_window_width: usize,
    dw_window_height: usize,

    pub fn init() OffsetTable {
        return .{
            .dw_entity_list = offsets.client_dll.dwEntityList,
            .dw_local_player_pawn = offsets.client_dll.dwLocalPlayerPawn,
            .dw_network_game_client = offsets.engine2_dll.dwNetworkGameClient,
            .dw_network_game_client_max_clients = offsets.engine2_dll.dwNetworkGameClient_maxClients,
            .dw_network_game_client_sign_on_state = offsets.engine2_dll.dwNetworkGameClient_signOnState,
            .dw_view_matrix = offsets.client_dll.dwViewMatrix,
            .dw_window_width = offsets.engine2_dll.dwWindowWidth,
            .dw_window_height = offsets.engine2_dll.dwWindowHeight,
        };
    }
};

pub const SchemaTable = struct {
    m_p_game_scene_node: usize,
    m_vec_abs_origin: usize,
    m_h_player_pawn: usize,
    m_h_pawn: usize,
    m_i_health: usize,
    m_i_team_num: usize,
    m_life_state: usize,
    m_v_old_origin: usize,

    pub fn init() SchemaTable {
        return .{
            .m_p_game_scene_node = client_schema.C_BaseEntity.m_pGameSceneNode,
            .m_vec_abs_origin = client_schema.CGameSceneNode.m_vecAbsOrigin,
            .m_h_player_pawn = client_schema.CCSPlayerController.m_hPlayerPawn,
            .m_h_pawn = client_schema.CBasePlayerController.m_hPawn,
            .m_i_health = client_schema.C_BaseEntity.m_iHealth,
            .m_i_team_num = client_schema.C_BaseEntity.m_iTeamNum,
            .m_life_state = client_schema.C_BaseEntity.m_lifeState,
            .m_v_old_origin = client_schema.C_BasePlayerPawn.m_vOldOrigin,
        };
    }
};

pub const Database = struct {
    offsets: OffsetTable,
    client: SchemaTable,

    pub fn init() !Database {
        return .{
            .offsets = OffsetTable.init(),
            .client = SchemaTable.init(),
        };
    }

    pub fn deinit(_: *Database) void {}
};

test "offset table returns client offset" {
    const table = OffsetTable.init();

    try std.testing.expectEqual(offsets.client_dll.dwLocalPlayerPawn, table.dw_local_player_pawn);
}

test "schema table returns client class fields" {
    const schema = SchemaTable.init();

    try std.testing.expectEqual(client_schema.C_BaseEntity.m_pGameSceneNode, schema.m_p_game_scene_node);
    try std.testing.expectEqual(client_schema.C_BasePlayerPawn.m_vOldOrigin, schema.m_v_old_origin);
}

test "database exposes offset and schema tables" {
    var db = try Database.init();
    defer db.deinit();

    try std.testing.expectEqual(offsets.client_dll.dwEntityList, db.offsets.dw_entity_list);
    try std.testing.expectEqual(offsets.client_dll.dwViewMatrix, db.offsets.dw_view_matrix);
    try std.testing.expectEqual(offsets.engine2_dll.dwWindowWidth, db.offsets.dw_window_width);
    try std.testing.expectEqual(offsets.engine2_dll.dwWindowHeight, db.offsets.dw_window_height);
    try std.testing.expectEqual(client_schema.CGameSceneNode.m_vecAbsOrigin, db.client.m_vec_abs_origin);
}
