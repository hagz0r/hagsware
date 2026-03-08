const std = @import("std");

const win32 = @import("win32");
const library_loader = win32.system.library_loader;
const memory = win32.system.memory;

pub const wildcard: i16 = -1;

pub const ModuleInfo = struct {
    name: [:0]const u8,
    signature: []const u8,
};

// Parses example pattern: AA BB ?? CC ? DD
pub fn signatureToBytes(allocator: std.mem.Allocator, pattern: []const u8) ![]i16 {
    var list: std.ArrayList(i16) = .empty;
    errdefer list.deinit(allocator);

    var it = std.mem.tokenizeScalar(u8, pattern, ' ');
    while (it.next()) |token| {
        if (token.len == 0) continue;
        if (std.mem.eql(u8, token, "?") or std.mem.eql(u8, token, "??")) {
            try list.append(allocator, wildcard);
            continue;
        }

        const value = try std.fmt.parseInt(u8, token, 16);
        try list.append(allocator, @as(i16, value));
    }

    return list.toOwnedSlice(allocator);
}

pub fn scanSimd(
    buffer: []const u8,
    pattern: []const i16,
) ?usize {
    if (pattern.len == 0 or buffer.len < pattern.len) return null;

    var pos: usize = 0;
    while (pos + pattern.len <= buffer.len) : (pos += 1) {
        if (matchAt(buffer, pattern, pos)) {
            return pos;
        }
    }

    return null;
}

fn matchAt(
    buffer: []const u8,
    pattern: []const i16,
    pos: usize,
) bool {
    for (pattern, 0..) |p, j| {
        if (p == wildcard) continue;
        if (buffer[pos + j] != @as(u8, @intCast(p))) return false;
    }
    return true;
}

// we would scan module for pattern we found,
// naive O(n*m) scan for the whole section would be slow
// so we can scan .text section or all sections with IMAGE_SCN_MEM_EXECUTE flag
// and use cool Zig's SIMD operations to find byte substring in given module
// can be improved with changing algorithm to Bayes-Moore algo for searching substring

pub fn resolveModule(module: ModuleInfo) ?*u8 {
    const moduleHandle = library_loader.GetModuleHandleA(module.name) orelse
        return null;

    const module_base = @intFromPtr(moduleHandle);

    const pattern = signatureToBytes(std.heap.page_allocator, module.signature) catch return null;
    defer std.heap.page_allocator.free(pattern);

    var addr = module_base;
    while (true) {
        var mbi: memory.MEMORY_BASIC_INFORMATION = undefined;
        const queried = memory.VirtualQuery(
            @as(*const anyopaque, @ptrFromInt(addr)),
            &mbi,
            @sizeOf(memory.MEMORY_BASIC_INFORMATION),
        );
        if (queried == 0) break;

        const region_base = @intFromPtr(mbi.BaseAddress orelse break);
        const allocation_base = @intFromPtr(mbi.AllocationBase orelse break);
        const region_size = mbi.RegionSize;

        if (region_base > module_base and allocation_base != module_base) break;

        if (allocation_base == module_base and isReadableRegion(mbi)) {
            const buffer = @as([*]const u8, @ptrFromInt(region_base))[0..region_size];
            if (scanSimd(buffer, pattern)) |offset| {
                const resolved_addr = std.math.add(usize, region_base, offset) catch return null;
                return @as(*u8, @ptrFromInt(resolved_addr));
            }
        }

        addr = std.math.add(usize, region_base, region_size) catch break;
    }

    return null;
}

fn isReadableRegion(mbi: memory.MEMORY_BASIC_INFORMATION) bool {
    if (mbi.State.COMMIT == 0) return false;
    if (mbi.Protect.PAGE_NOACCESS == 1 or mbi.Protect.PAGE_GUARD == 1) return false;

    return mbi.Protect.PAGE_READONLY == 1 or
        mbi.Protect.PAGE_READWRITE == 1 or
        mbi.Protect.PAGE_WRITECOPY == 1 or
        mbi.Protect.PAGE_EXECUTE_READ == 1 or
        mbi.Protect.PAGE_EXECUTE_READWRITE == 1 or
        mbi.Protect.PAGE_EXECUTE_WRITECOPY == 1;
}

pub fn resolveModuleRead(comptime T: type, module: ModuleInfo, read_offset: usize) ?T {
    const pattern_addr = resolveModule(module) orelse return null;
    const value_addr = std.math.add(usize, @intFromPtr(pattern_addr), read_offset) catch return null;
    return @as(*align(1) const T, @ptrFromInt(value_addr)).*;
}

pub fn readRelativeAddress(displacement_addr: usize, offset_to_next_instruction: usize) ?usize {
    const displacement = @as(*align(1) const i32, @ptrFromInt(displacement_addr)).*;
    const next_instruction_addr = std.math.add(usize, displacement_addr, offset_to_next_instruction) catch return null;

    const next_instruction_signed = std.math.cast(isize, next_instruction_addr) orelse return null;
    const target_signed = std.math.add(isize, next_instruction_signed, @as(isize, displacement)) catch return null;
    return std.math.cast(usize, target_signed);
}

pub fn resolveModuleAbs(
    module: ModuleInfo,
    displacement_offset: usize,
    offset_to_next_instruction: usize,
) ?usize {
    const pattern_addr = resolveModule(module) orelse return null;
    const displacement_addr = std.math.add(usize, @intFromPtr(pattern_addr), displacement_offset) catch return null;
    return readRelativeAddress(displacement_addr, offset_to_next_instruction);
}
