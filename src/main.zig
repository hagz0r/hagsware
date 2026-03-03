const win32 = @import("win32");
const logger = @import("log.zig");
const foundation = win32.foundation;
const library_loader = win32.system.library_loader;
const threading = win32.system.threading;
const system_services = win32.system.system_services;
const w = win32.zig;

fn bootstrap(lp_param: ?*anyopaque) callconv(.winapi) u32 {
    logger.info("Bootstrap thread created: {?}", .{lp_param});
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
        logger.info("DLL_PROCESS_ATTACH", .{});

        const thread_handle = threading.CreateThread(null, 0, bootstrap, null, .{}, null);
        if (thread_handle) |handle| {
            _ = foundation.CloseHandle(handle);
        } else {
            logger.err("CreateThread failed: 0x{x}", .{foundation.GetLastError()});
        }
    }

    return w.TRUE;
}
