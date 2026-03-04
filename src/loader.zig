const std = @import("std");
const win32 = @import("win32");
const foundation = win32.foundation;
const library_loader = win32.system.library_loader;
const w = win32.zig;

const SelfTestFn = *const fn () callconv(.winapi) u32;

pub fn main() !void {
    const module = library_loader.LoadLibraryW(w.L("zig-out\\bin\\hagsware.dll")) orelse {
        std.log.err("LoadLibraryW failed: {f}", .{foundation.GetLastError()});
        return error.DllLoadFailed;
    };

    const proc = library_loader.GetProcAddress(module, "self_test") orelse {
        std.log.err("GetProcAddress(self_test) failed", .{});
        return error.SymbolNotFound;
    };

    const self_test: SelfTestFn = @ptrCast(proc);
    const result = self_test();
    std.debug.print("self_test() => 0x{x}\n", .{result});

    if (result != 0xDEADBEEF) {
        return error.SelfTestMismatch;
    }
}
