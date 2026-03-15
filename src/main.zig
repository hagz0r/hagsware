const std = @import("std");
const win32 = @import("win32");

const dumper = @import("dumper/mod.zig");
const hacks_mod = @import("hacks.zig");
const logger = @import("log.zig");
const render = @import("render/mod.zig");
const utils = @import("utils/mod.zig");

const foundation = win32.foundation;
const library_loader = win32.system.library_loader;
const system_services = win32.system.system_services;
const threading = win32.system.threading;
const w = win32.zig;

const UPDATE_INTERVAL_NS: i128 = @as(i128, std.time.ns_per_s / 128);
const IDLE_SLEEP_NS: i128 = 1_000_000;
const MAX_CATCHUP_STEPS: usize = 4;
var self_module: ?foundation.HINSTANCE = null;

fn bootstrap(lp_param: ?*anyopaque) callconv(.winapi) u32 {
    logger.info("Bootstrap thread created: {?}", .{lp_param});

    var db = dumper.Database.init() catch |err| {
        logger.err("Database.init failed: {s}", .{@errorName(err)});
        return 1;
    };
    defer db.deinit();

    var registry: hacks_mod.Registry = undefined;
    registry.init(&db) catch |err| {
        logger.err("Registry.init failed: {s}", .{@errorName(err)});
        return 1;
    };
    logger.info("Registry.init done: client_base=0x{x}, engine2_base=0x{x}", .{ registry.app.game.client_base, registry.app.game.engine2_base });

    registry.initAll() catch |err| {
        logger.err("Registry.initAll failed: {s}", .{@errorName(err)});
        return 1;
    };
    logger.info("Registry.initAll done", .{});

    var next_update_ns: i128 = std.time.nanoTimestamp();
    while (!utils.panicPressed()) {
        render.ensureInternalPresentHook();

        var now_ns: i128 = std.time.nanoTimestamp();
        var steps: usize = 0;
        while (now_ns >= next_update_ns and steps < MAX_CATCHUP_STEPS) : (steps += 1) {
            const scene_loaded = utils.isSceneLoaded(registry) catch |err| {
                logger.err("isSceneLoaded failed: {s}", .{@errorName(err)});
                next_update_ns += UPDATE_INTERVAL_NS;
                now_ns = std.time.nanoTimestamp();
                continue;
            };

            if (scene_loaded) {
                registry.updateAll() catch |err| {
                    logger.err("Registry.updateAll failed: {s}", .{@errorName(err)});
                    return 1;
                };
            } else {
                render.beginCommands();
                render.endCommands();
            }

            next_update_ns += UPDATE_INTERVAL_NS;
            now_ns = std.time.nanoTimestamp();
        }

        if (steps == MAX_CATCHUP_STEPS and now_ns >= next_update_ns) {
            next_update_ns = now_ns + UPDATE_INTERVAL_NS;
        }

        const sleep_ns = next_update_ns - now_ns;
        if (sleep_ns > 0) {
            std.Thread.sleep(@intCast(@min(sleep_ns, IDLE_SLEEP_NS)));
        }
    }

    logger.info("Bootstrap loop ended: panic key pressed", .{});
    render.shutdown();
    logger.info("Bootstrap unloading: module={?}", .{self_module});
    if (self_module) |module| {
        library_loader.FreeLibraryAndExitThread(module, 0);
    }
    threading.ExitThread(0);
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
        self_module = hinst_dll;
        _ = library_loader.DisableThreadLibraryCalls(hinst_dll);

        const thread_handle = threading.CreateThread(null, 0, bootstrap, null, .{}, null);
        if (thread_handle) |handle| {
            _ = foundation.CloseHandle(handle);
        } else {
            return w.FALSE;
        }
    }

    return w.TRUE;
}
