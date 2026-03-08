const std = @import("std");
const win32 = @import("win32");

const memory = win32.system.memory;

pub fn read(comptime T: type, addr: usize) ?T {
    if (!isReadable(addr, @sizeOf(T))) return null;
    return @as(*const T, @ptrFromInt(addr)).*;
}

pub fn isReadable(addr: usize, size: usize) bool {
    if (addr == 0 or size == 0) return false;

    var mbi: memory.MEMORY_BASIC_INFORMATION = undefined;
    const queried = memory.VirtualQuery(
        @as(*const anyopaque, @ptrFromInt(addr)),
        &mbi,
        @sizeOf(memory.MEMORY_BASIC_INFORMATION),
    );
    if (queried == 0) return false;
    if (mbi.State.COMMIT == 0) return false;
    if (mbi.Protect.PAGE_NOACCESS == 1 or mbi.Protect.PAGE_GUARD == 1) return false;

    const readable =
        mbi.Protect.PAGE_READONLY == 1 or
        mbi.Protect.PAGE_READWRITE == 1 or
        mbi.Protect.PAGE_WRITECOPY == 1 or
        mbi.Protect.PAGE_EXECUTE_READ == 1 or
        mbi.Protect.PAGE_EXECUTE_READWRITE == 1 or
        mbi.Protect.PAGE_EXECUTE_WRITECOPY == 1;
    if (!readable) return false;

    const base_address = @intFromPtr(mbi.BaseAddress orelse return false);
    const region_size = mbi.RegionSize;
    const end_address = std.math.add(usize, base_address, region_size) catch return false;
    const read_end = std.math.add(usize, addr, size) catch return false;

    return addr >= base_address and read_end <= end_address;
}
