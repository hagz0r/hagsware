const std = @import("std");
const win = std.os.windows;
const DLL_PROCESS_ATTACH: win.DWORD = 1;

fn bootstrap(lp_param: win.LPVOID) callconv(.winapi) win.DWORD {
    std.debug.print("Bootstrap thread created: {}\n", .{lp_param});
    return 0;
}

pub export fn self_test() callconv(.winapi) u32 {
    return 0xDEADBEEF;
}

pub fn DllMain(
    hinst_dll: win.HINSTANCE,
    fdw_reason: win.DWORD,
    lpv_reserved: win.LPVOID,
) callconv(.winapi) win.BOOL {
    _ = hinst_dll;
    _ = lpv_reserved;

    if (fdw_reason == DLL_PROCESS_ATTACH) {
        const thread_handle = win.kernel32.CreateThread(null, 0, bootstrap, null, 0, null);
        if (thread_handle) |handle| {
            win.CloseHandle(handle);
        }
    }

    return win.TRUE;
}
