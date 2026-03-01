const std = @import("std");

const win32 = @import("win32");
const foundation = win32.foundation;
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
    var list = std.ArrayList(i16).init(allocator);
    errdefer list.deinit();

    var it = std.mem.tokenizeScalar(u8, pattern, ' ');
    while (it.next()) |token| {
        if (token.len == 0) continue;
        if (std.mem.eql(u8, token, "?") or std.mem.eql(u8, token, "??")) {
            try list.append(wildcard);
            continue;
        }

        const value = try std.fmt.parseInt(u8, token, 16);
        try list.append(@as(i16, value));
    }

    return list.toOwnedSlice();
}
pub fn scanSimd(
    buffer: []const u8,
    pattern: []const i32,
) ?usize {
    var anchor_index: usize = 0;
    var found_anchor = false;

    for (pattern, 0..) |b, i| {
        if (b != -1) {
            anchor_index = i;
            found_anchor = true;
            break;
        }
    }
    if (!found_anchor)
        return null;

    const anchor_byte: u8 = @intCast(pattern[anchor_index]);
    const Vec = @Vector(32, u8); // AVX2 256-bit
    const anchor_vec: Vec = @splat(anchor_byte);

    var i: usize = 0;

    while (i + 32 <= buffer.len) : (i += 32) {
        const chunk: Vec = buffer[i..][0..32].*;

        const cmp = chunk == anchor_vec;
        const mask = @as(u32, cmp);

        if (mask != 0) {
            var bit: u32 = mask;
            while (bit != 0) {
                const offset = @ctz(bit);
                const pos = i + offset;

                if (pos + pattern.len > buffer.len)
                    return null;

                if (matchAt(buffer, pattern, pos))
                    return pos;

                bit &= bit - 1;
            }
        }
    }

    return null;
}

fn matchAt(
    buffer: []const u8,
    pattern: []const i32,
    pos: usize,
) bool {
    for (pattern, 0..) |p, j| {
        if (p == -1)
            continue;

        if (buffer[pos + j] != @as(u8, @intCast(p)))
            return false;
    }
    return true;
}

fn findTextSection(base: [*]const u8, nt_headers: dbg.IMAGE_NT_HEADERS64) ?struct { start: [*]const u8, size: usize } {
    const nt = nt_headers;
    const sections: [*]const dbg.IMAGE_SECTION_HEADER = @as(
        [*]const dbg.IMAGE_SECTION_HEADER,
        @ptrCast(@as([*]const u8, @ptrCast(nt)) + @sizeOf(dbg.IMAGE_NT_HEADERS64)),
    );

    var i: usize = 0;
    while (i < nt.FileHeader.NumberOfSections) : (i += 1) {
        const sec = sections[i];

        const name = sec.Name;

        if (std.mem.eql(u8, name[0..5], ".text")) {
            const start = base + sec.VirtualAddress;
            const size = sec.Misc.VirtualSize;
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

    const text = findTextSection(base) orelse
        return null;

    const buffer = text.start[0..text.size];

    const pattern = signatureToBytes(std.heap.page_allocator, module.signature) catch return null;
    defer std.heap.page_allocator.free(pattern);

    if (scanSimd(buffer, pattern)) |offset| {
        return @as(*u8, @ptrCast(text.start + offset));
    }

    return null;
}
