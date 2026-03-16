const std = @import("std");
const log = @import("../log.zig");
const signatures = @import("../signatures/mod.zig");
const mem = @import("../utils/memory.zig");

pub const sig_entity_system_pointer = signatures.ModuleInfo{
    .name = "client.dll",
    .signature = "48 89 ? ? ? ? ? 4C 63 ? ? ? ? ? 44 3B ? ? ? ? ? 0F",
};

pub const sig_entity_list_offset = signatures.ModuleInfo{
    .name = "client.dll",
    .signature = "48 8D ? ? E8 ? ? ? ? 8D 85",
};

pub const Resolved = struct {
    entity_system_pointer_addr: usize,
    entity_list_offset: usize,
};

var resolved: ?Resolved = null;

pub fn init() !void {
    if (resolved != null) return;
    resolved = try resolvePatterns();
}

pub fn getEntityList() ?usize {
    const state = resolved orelse return null;
    const entity_system = mem.read(usize, state.entity_system_pointer_addr) orelse return null;
    if (entity_system == 0) return null;
    return entity_system + state.entity_list_offset;
}

fn resolvePatterns() !Resolved {
    const entity_system_pattern = signatures.resolveModule(sig_entity_system_pointer) orelse {
        return error.EntitySystemPointerPatternNotFound;
    };
    const entity_system_disp_addr = @intFromPtr(entity_system_pattern) + 3;
    const entity_system_pointer_addr = signatures.readRelativeAddress(entity_system_disp_addr, 4) orelse {
        return error.EntitySystemPointerResolveFailed;
    };
    const entity_list_offset = resolveEntityListOffset() orelse {
        return error.EntityListOffsetPatternNotFound;
    };

    log.info(
        "EntitySystem signatures ready: ent_sys_pat=0x{x}, ent_sys_ptr=0x{x}, ent_list_off=0x{x}",
        .{
            @intFromPtr(entity_system_pattern),
            entity_system_pointer_addr,
            entity_list_offset,
        },
    );

    return .{
        .entity_system_pointer_addr = entity_system_pointer_addr,
        .entity_list_offset = entity_list_offset,
    };
}

fn resolveEntityListOffset() ?usize {
    if (signatures.resolveModuleRead(i8, sig_entity_list_offset, 3)) |offset8| {
        if (offset8 > 0) return @as(usize, @intCast(offset8));
    }
    return null;
}
