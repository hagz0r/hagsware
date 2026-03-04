const win32 = @import("win32");
const std = @import("std");
const logger = @import("log.zig");
const foundation = win32.foundation;
const library_loader = win32.system.library_loader;
const memory = win32.system.memory;
const threading = win32.system.threading;
const system_services = win32.system.system_services;
const input = win32.ui.input;
const dumper = @import("dumper/mod.zig");

const w = win32.zig;

fn print_pos() void {
    var db = dumper.Database.init(std.heap.page_allocator) catch {
        logger.err("Database.init failed", .{});
        return;
    };
    defer db.deinit();

    const client_module = library_loader.GetModuleHandleA("client.dll") orelse {
        logger.err("client.dll is not loaded", .{});
        return;
    };

    const dw_local_player_pawn = db.offsets.get("client.dll", "dwLocalPlayerPawn") catch {
        logger.err("dwLocalPlayerPawn not found", .{});
        return;
    };
    const m_v_old_origin = db.client.field("C_BasePlayerPawn", "m_vOldOrigin") catch {
        logger.err("C_BasePlayerPawn::m_vOldOrigin not found", .{});
        return;
    };

    const client_base = @intFromPtr(client_module);
    const pawn_ptr_addr = client_base + dw_local_player_pawn;
    if (!isReadableAddress(pawn_ptr_addr, @sizeOf(usize))) {
        logger.err("pawn pointer address is unreadable: 0x{x}", .{pawn_ptr_addr});
        return;
    }
    if (!std.mem.isAligned(pawn_ptr_addr, @alignOf(usize))) {
        logger.err("pawn pointer address is unaligned: 0x{x}", .{pawn_ptr_addr});
        return;
    }

    const pawn = @as(*const usize, @ptrFromInt(pawn_ptr_addr)).*;
    if (pawn == 0) {
        logger.err("local pawn pointer is null", .{});
        return;
    }

    const pos_addr = pawn + m_v_old_origin;
    if (!isReadableAddress(pos_addr, @sizeOf([3]f32))) {
        logger.err("position address is unreadable: 0x{x}", .{pos_addr});
        return;
    }
    if (!std.mem.isAligned(pos_addr, @alignOf([3]f32))) {
        logger.err("position address is unaligned: 0x{x}", .{pos_addr});
        return;
    }

    const pos = @as(*const [3]f32, @ptrFromInt(pos_addr)).*;

    logger.info("client_base: 0x{x}", .{client_base});
    logger.info("pawn: 0x{x}", .{pawn});
    logger.info("m_vOldOrigin: x={d:.3} y={d:.3} z={d:.3}", .{ pos[0], pos[1], pos[2] });
}

fn isReadableAddress(address: usize, size: usize) bool {
    if (address == 0 or size == 0) return false;

    var mbi: memory.MEMORY_BASIC_INFORMATION = undefined;
    const queried = memory.VirtualQuery(
        @as(*const anyopaque, @ptrFromInt(address)),
        &mbi,
        @sizeOf(memory.MEMORY_BASIC_INFORMATION),
    );
    if (queried == 0) return false;
    if (mbi.State.COMMIT == 0) return false;
    if (mbi.Protect.PAGE_NOACCESS == 1 or mbi.Protect.PAGE_GUARD == 1) return false;

    const readable = mbi.Protect.PAGE_READONLY == 1 or
        mbi.Protect.PAGE_READWRITE == 1 or
        mbi.Protect.PAGE_WRITECOPY == 1 or
        mbi.Protect.PAGE_EXECUTE_READ == 1 or
        mbi.Protect.PAGE_EXECUTE_READWRITE == 1 or
        mbi.Protect.PAGE_EXECUTE_WRITECOPY == 1 or
        mbi.Protect.PAGE_GRAPHICS_READONLY == 1 or
        mbi.Protect.PAGE_GRAPHICS_READWRITE == 1 or
        mbi.Protect.PAGE_GRAPHICS_EXECUTE_READ == 1 or
        mbi.Protect.PAGE_GRAPHICS_EXECUTE_READWRITE == 1;
    if (!readable) return false;

    const base = @intFromPtr(mbi.BaseAddress orelse return false);
    const region_end = base + mbi.RegionSize;
    const read_end = address + size;
    return address >= base and read_end <= region_end;
}

fn bootstrap(lp_param: ?*anyopaque) callconv(.winapi) u32 {
    logger.info("Bootstrap thread created: {?}", .{lp_param});
    const vk_end: i32 = @as(i32, @intFromEnum(input.keyboard_and_mouse.VK_END));
    while (input.keyboard_and_mouse.GetKeyState(vk_end) >= 0) {
        print_pos();
        std.Thread.sleep(1_000_000);
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
