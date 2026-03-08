const std = @import("std");

const win32 = @import("win32");
const library_loader = win32.system.library_loader;
const dbg = win32.system.diagnostics.debug;
const sysserv = win32.system.system_services;

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

fn findTextSection(base: [*]const u8) ?struct { start: [*]const u8, size: usize } {
    const base_addr = @intFromPtr(base);

    const dos_header = @as(*const sysserv.IMAGE_DOS_HEADER, @ptrFromInt(base_addr));
    const nt_headers_addr = std.math.add(
        usize,
        base_addr,
        @as(usize, @intCast(dos_header.e_lfanew)),
    ) catch return null;
    const nt_headers = @as(*const dbg.IMAGE_NT_HEADERS64, @ptrFromInt(nt_headers_addr));

    const sections: [*]const dbg.IMAGE_SECTION_HEADER = @as(
        [*]const dbg.IMAGE_SECTION_HEADER,
        @ptrFromInt(nt_headers_addr + @sizeOf(dbg.IMAGE_NT_HEADERS64)),
    );

    var i: usize = 0;
    while (i < @as(usize, @intCast(nt_headers.FileHeader.NumberOfSections))) : (i += 1) {
        const sec = sections[i];
        if (std.mem.eql(u8, sec.Name[0..5], ".text")) {
            const start_addr = std.math.add(
                usize,
                base_addr,
                @as(usize, @intCast(sec.VirtualAddress)),
            ) catch return null;
            const start = @as([*]const u8, @ptrFromInt(start_addr));
            const size = @as(usize, @intCast(sec.Misc.VirtualSize));
            return .{ .start = start, .size = size };
        }
    }

    return null;
}

// we would scan module for pattern we found,
// naive O(n*m) scan for the whole section would be slow
// so we can scan .text section or all sections with IMAGE_SCN_MEM_EXECUTE flag
// and use cool Zig's SIMD operations to find byte substring in given module
// can be improved with changing algorithm to Bayes-Moore algo for searching substring

pub fn resolveModule(module: ModuleInfo) ?*u8 {
    const moduleHandle = library_loader.GetModuleHandleA(module.name) orelse
        return null;

    const base = @as([*]const u8, @ptrCast(moduleHandle));
    const text = findTextSection(base) orelse return null;

    const buffer = text.start[0..text.size];

    const pattern = signatureToBytes(std.heap.page_allocator, module.signature) catch return null;
    defer std.heap.page_allocator.free(pattern);

    if (scanSimd(buffer, pattern)) |offset| {
        const resolved_addr = std.math.add(usize, @intFromPtr(text.start), offset) catch return null;
        return @as(*u8, @ptrFromInt(resolved_addr));
    }

    return null;
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
