const std = @import("std");

pub const LookupError = error{
    InvalidJsonShape,
    InvalidOffsetType,
    ModuleNotFound,
    OffsetNotFound,
    ClassNotFound,
    FieldNotFound,
};

pub const OffsetTable = struct {
    parsed: std.json.Parsed(std.json.Value),

    pub fn initEmbedded(allocator: std.mem.Allocator, comptime file_name: []const u8) !OffsetTable {
        const parsed = try parseEmbeddedJson(allocator, file_name);
        return .{
            .parsed = parsed,
        };
    }

    pub fn deinit(self: *OffsetTable) void {
        self.parsed.deinit();
    }

    pub fn get(self: *const OffsetTable, module_name: []const u8, offset_name: []const u8) LookupError!usize {
        const root = try valueAsObject(self.parsed.value);
        const module_value = root.get(module_name) orelse return error.ModuleNotFound;
        const module_object = try valueAsObject(module_value);
        const offset_value = module_object.get(offset_name) orelse return error.OffsetNotFound;
        return valueToOffset(offset_value);
    }
};

pub const SchemaTable = struct {
    parsed: std.json.Parsed(std.json.Value),
    module_name: []const u8,

    pub fn initEmbedded(
        allocator: std.mem.Allocator,
        comptime file_name: []const u8,
        module_name: []const u8,
    ) !SchemaTable {
        const parsed = try parseEmbeddedJson(allocator, file_name);
        return .{
            .parsed = parsed,
            .module_name = module_name,
        };
    }

    pub fn deinit(self: *SchemaTable) void {
        self.parsed.deinit();
    }

    pub fn field(self: *const SchemaTable, class_name: []const u8, field_name: []const u8) LookupError!usize {
        const root = try valueAsObject(self.parsed.value);
        const module_value = root.get(self.module_name) orelse return error.ModuleNotFound;
        const module_object = try valueAsObject(module_value);
        const classes_value = module_object.get("classes") orelse return error.InvalidJsonShape;
        const classes_object = try valueAsObject(classes_value);
        const class_value = classes_object.get(class_name) orelse return error.ClassNotFound;
        const class_object = try valueAsObject(class_value);
        const fields_value = class_object.get("fields") orelse return error.InvalidJsonShape;
        const fields_object = try valueAsObject(fields_value);
        const field_value = fields_object.get(field_name) orelse return error.FieldNotFound;
        return valueToOffset(field_value);
    }
};

pub const Database = struct {
    offsets: OffsetTable,
    client: SchemaTable,

    pub fn init(allocator: std.mem.Allocator) !Database {
        var offsets = try OffsetTable.initEmbedded(allocator, "offsets.json");
        errdefer offsets.deinit();

        var client = try SchemaTable.initEmbedded(allocator, "client_dll.json", "client.dll");
        errdefer client.deinit();

        return .{
            .offsets = offsets,
            .client = client,
        };
    }

    pub fn deinit(self: *Database) void {
        self.client.deinit();
        self.offsets.deinit();
    }
};

fn parseEmbeddedJson(
    allocator: std.mem.Allocator,
    comptime file_name: []const u8,
) !std.json.Parsed(std.json.Value) {
    const file_contents = @embedFile(file_name);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, file_contents, .{});
    errdefer parsed.deinit();

    _ = try valueAsObject(parsed.value);
    return parsed;
}

fn valueAsObject(value: std.json.Value) LookupError!std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.InvalidJsonShape,
    };
}

fn valueToOffset(value: std.json.Value) LookupError!usize {
    return switch (value) {
        .integer => |int_value| {
            if (int_value < 0) return error.InvalidOffsetType;
            return @as(usize, @intCast(int_value));
        },
        .float => |float_value| {
            const floor_value = @floor(float_value);
            if (float_value < 0 or floor_value != float_value) return error.InvalidOffsetType;
            return @as(usize, @intFromFloat(floor_value));
        },
        .number_string => |number_string| std.fmt.parseInt(usize, number_string, 10) catch return error.InvalidOffsetType,
        else => error.InvalidOffsetType,
    };
}

test "offset table returns client offset" {
    var table = try OffsetTable.initEmbedded(std.testing.allocator, "offsets.json");
    defer table.deinit();

    const dw_local_player_pawn = try table.get("client.dll", "dwLocalPlayerPawn");
    try std.testing.expectEqual(@as(usize, 33970928), dw_local_player_pawn);
}

test "schema table returns client class fields" {
    var schema = try SchemaTable.initEmbedded(std.testing.allocator, "client_dll.json", "client.dll");
    defer schema.deinit();

    const m_p_game_scene_node = try schema.field("C_BaseEntity", "m_pGameSceneNode");
    try std.testing.expectEqual(@as(usize, 824), m_p_game_scene_node);

    const m_v_old_origin = try schema.field("C_BasePlayerPawn", "m_vOldOrigin");
    try std.testing.expectEqual(@as(usize, 5512), m_v_old_origin);
}

test "database exposes offset and schema tables" {
    var db = try Database.init(std.testing.allocator);
    defer db.deinit();

    const entity_list = try db.offsets.get("client.dll", "dwEntityList");
    try std.testing.expectEqual(@as(usize, 38449592), entity_list);

    const scene_abs_origin = try db.client.field("CGameSceneNode", "m_vecAbsOrigin");
    try std.testing.expectEqual(@as(usize, 208), scene_abs_origin);
}
