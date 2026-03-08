const std = @import("std");
const dumper = @import("../dumper/mod.zig");

pub const Vec3 = @import("types.zig").Vec3;

pub const Entity = struct {
    name: []const u8,
    origin: Vec3,
};

pub fn get_entity_list(allocator: std.mem.Allocator, db: *dumper.Database) !std.ArrayList(Entity) {
    _ = allocator;
    _ = try db.offsets.get("client.dll", "dwEntityList");
    return std.ArrayList(Entity).empty;
}
