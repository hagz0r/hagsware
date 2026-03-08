const std = @import("std");
const win32 = @import("win32");

const dumper = @import("dumper/mod.zig");
const hacks_mod = @import("hacks.zig");
const logger = @import("log.zig");

const foundation = win32.foundation;
const library_loader = win32.system.library_loader;
const system_services = win32.system.system_services;
const threading = win32.system.threading;
const kb = win32.ui.input.keyboard_and_mouse;
const w = win32.zig;

fn bootstrap(lp_param: ?*anyopaque) callconv(.winapi) u32 {
    logger.info("Bootstrap thread created: {?}", .{lp_param});

    var db = dumper.Database.init(std.heap.page_allocator) catch |err| {
        logger.err("Database.init failed: {s}", .{@errorName(err)});
        return 1;
    };
    defer db.deinit();

    var registry: hacks_mod.Registry = undefined;
    registry.init(&db);

    registry.initAll() catch |err| {
        logger.err("Registry.initAll failed: {s}", .{@errorName(err)});
        return 1;
    };

    while (!kb.GetKeyState(kb.VK_END)) {
        registry.updateAll() catch |err| {
            logger.err("Registry.updateAll failed: {s}", .{@errorName(err)});
            return 1;
        };

        std.Thread.sleep(10_000_000); // 10 ms
    }

    return 0;
}

pub export fn self_test() callconv(.winapi) u32 {
    return 0xDEADBEEF;
}

pub fn DllMain(
    hinst_dll: ?foundation.HINSTANCE,
    fdw_reason: u32,
    lpv_reserved: ?*anyopaque,
) callconv(.winapi) foundation.BOOL {
    _ = lpv_reserved;

    if (fdw_reason == system_services.DLL_PROCESS_ATTACH) {
        _ = library_loader.DisableThreadLibraryCalls(hinst_dll);

        const thread_handle = threading.CreateThread(null, 0, bootstrap, null, .{}, null);
        if (thread_handle) |handle| {
            _ = foundation.CloseHandle(handle);
        } else {
            logger.err("CreateThread failed: 0x{x}", .{foundation.GetLastError()});
        }
    }

    return w.TRUE;
}
