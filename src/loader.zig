const std = @import("std");
const win = std.os.windows;

const SelfTestFn = *const fn () callconv(.winapi) u32;

pub fn main() !void {
    const dll_path = std.unicode.utf8ToUtf16LeStringLiteral("zig-out\\bin\\hagsware.dll");
    const module = win.LoadLibraryW(dll_path) catch |err| {
        std.log.err("LoadLibraryW failed: {s}", .{@errorName(err)});
        return error.DllLoadFailed;
    };
    defer win.FreeLibrary(module);

    const proc = win.kernel32.GetProcAddress(module, "self_test") orelse {
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
