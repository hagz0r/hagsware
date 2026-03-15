const std = @import("std");
const win32 = @import("win32");
const log = @import("../log.zig");
const Vec2 = @import("../utils/types.zig").Vec2;

const foundation = win32.foundation;
const d3d = win32.graphics.direct3d;
const d3d11 = win32.graphics.direct3d11;
const dxgi = win32.graphics.dxgi;
const memory = win32.system.memory;
const threading = win32.system.threading;
const windows_and_messaging = win32.ui.windows_and_messaging;
const w = win32.zig;

pub const color_enemy: u32 = rgb(255, 64, 64);
pub const color_friendly: u32 = rgb(64, 192, 255);
pub const color_debug: u32 = rgb(255, 255, 255);

const max_commands = 512;

const PresentFn = *const fn (
    self: *const dxgi.IDXGISwapChain,
    sync_interval: u32,
    flags: u32,
) callconv(.winapi) foundation.HRESULT;

const CommandKind = enum {
    cross,
    box,
};

const DrawCommand = union(CommandKind) {
    cross: struct {
        pos: Vec2,
        radius: i32,
        color: u32,
    },
    box: struct {
        left: f32,
        top: f32,
        right: f32,
        bottom: f32,
        color: u32,
    },
};

var commands_mutex: std.Thread.Mutex = .{};
var commands: [max_commands]DrawCommand = undefined;
var command_count: usize = 0;
var build_mutex: std.Thread.Mutex = .{};
var build_commands: [max_commands]DrawCommand = undefined;
var build_count: usize = 0;

var present_hook_installed = std.atomic.Value(bool).init(false);
var shutdown_requested = std.atomic.Value(bool).init(false);
var active_present_calls = std.atomic.Value(usize).init(0);
var first_present_seen = std.atomic.Value(bool).init(false);
var first_draw_seen = std.atomic.Value(bool).init(false);
var hook_attempt_counter: usize = 0;
var original_present: ?PresentFn = null;
var present_slot: ?*PresentFn = null;
var hook_mutex: std.Thread.Mutex = .{};

pub fn ensureInternalPresentHook() void {
    if (shutdown_requested.load(.acquire)) return;
    if (present_hook_installed.load(.acquire)) return;

    hook_attempt_counter += 1;
    if (hook_attempt_counter > 1 and hook_attempt_counter % 100 != 0) return;

    if (installPresentHook()) {
        present_hook_installed.store(true, .release);
        log.info("Render hook installed: IDXGISwapChain::Present", .{});
    } else if (hook_attempt_counter % 200 == 0) {
        log.info("Render hook pending: waiting for active game window", .{});
    }
}

pub fn shutdown() void {
    shutdown_requested.store(true, .release);
    _ = uninstallPresentHook();

    var i: usize = 0;
    while (active_present_calls.load(.acquire) != 0 and i < 400) : (i += 1) {
        std.Thread.sleep(5_000_000);
    }

    commands_mutex.lock();
    defer commands_mutex.unlock();
    command_count = 0;

    build_mutex.lock();
    defer build_mutex.unlock();
    build_count = 0;
}

pub fn beginCommands() void {
    build_mutex.lock();
    build_count = 0;
}

pub fn endCommands() void {
    commands_mutex.lock();
    command_count = build_count;
    std.mem.copyForwards(DrawCommand, commands[0..build_count], build_commands[0..build_count]);
    commands_mutex.unlock();
    build_mutex.unlock();
}

pub fn pushCross(pos: Vec2, radius: i32, color: u32) void {
    if (build_count >= max_commands) return;
    build_commands[build_count] = .{
        .cross = .{
            .pos = pos,
            .radius = radius,
            .color = color,
        },
    };
    build_count += 1;
}

pub fn pushBox(left: f32, top: f32, right: f32, bottom: f32, color: u32) void {
    if (build_count >= max_commands) return;
    build_commands[build_count] = .{
        .box = .{
            .left = left,
            .top = top,
            .right = right,
            .bottom = bottom,
            .color = color,
        },
    };
    build_count += 1;
}

fn installPresentHook() bool {
    if (shutdown_requested.load(.acquire)) return false;

    const output_window = resolveTargetWindow() orelse return false;

    var desc: dxgi.DXGI_SWAP_CHAIN_DESC = std.mem.zeroes(dxgi.DXGI_SWAP_CHAIN_DESC);
    desc.BufferDesc.Width = 2;
    desc.BufferDesc.Height = 2;
    desc.BufferDesc.RefreshRate.Numerator = 60;
    desc.BufferDesc.RefreshRate.Denominator = 1;
    desc.BufferDesc.Format = @enumFromInt(28); // DXGI_FORMAT_R8G8B8A8_UNORM
    desc.SampleDesc.Count = 1;
    desc.SampleDesc.Quality = 0;
    desc.BufferUsage = dxgi.DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 1;
    desc.OutputWindow = output_window;
    desc.Windowed = w.TRUE;
    desc.SwapEffect = dxgi.DXGI_SWAP_EFFECT_DISCARD;
    desc.Flags = 0;

    var swap_chain: *dxgi.IDXGISwapChain = undefined;
    var device: *d3d11.ID3D11Device = undefined;
    var immediate_ctx: *d3d11.ID3D11DeviceContext = undefined;

    const hr = d3d11.D3D11CreateDeviceAndSwapChain(
        null,
        d3d.D3D_DRIVER_TYPE_HARDWARE,
        null,
        .{},
        null,
        0,
        d3d11.D3D11_SDK_VERSION,
        &desc,
        &swap_chain,
        &device,
        null,
        &immediate_ctx,
    );
    if (hr < 0) return false;

    const vtable_addr = @intFromPtr(swap_chain.vtable);
    const present_slot_addr = vtable_addr + @offsetOf(dxgi.IDXGISwapChain.VTable, "Present");
    const hook_slot = @as(*PresentFn, @ptrFromInt(present_slot_addr));

    hook_mutex.lock();
    defer hook_mutex.unlock();

    if (shutdown_requested.load(.acquire)) {
        _ = swap_chain.IUnknown.Release();
        _ = device.IUnknown.Release();
        _ = immediate_ctx.IUnknown.Release();
        return false;
    }

    const current_present = hook_slot.*;
    if (@intFromPtr(current_present) == @intFromPtr(&hkPresent)) {
        if (original_present == null) {
            _ = swap_chain.IUnknown.Release();
            _ = device.IUnknown.Release();
            _ = immediate_ctx.IUnknown.Release();
            return false;
        }

        present_slot = hook_slot;
        _ = swap_chain.IUnknown.Release();
        _ = device.IUnknown.Release();
        _ = immediate_ctx.IUnknown.Release();
        return true;
    }

    var old_protect: memory.PAGE_PROTECTION_FLAGS = undefined;
    if (memory.VirtualProtect(
        @as(*anyopaque, @ptrFromInt(present_slot_addr)),
        @sizeOf(PresentFn),
        memory.PAGE_EXECUTE_READWRITE,
        &old_protect,
    ) == 0) {
        _ = swap_chain.IUnknown.Release();
        _ = device.IUnknown.Release();
        _ = immediate_ctx.IUnknown.Release();
        return false;
    }

    original_present = current_present;
    present_slot = hook_slot;
    hook_slot.* = &hkPresent;

    var restore_dummy: memory.PAGE_PROTECTION_FLAGS = undefined;
    _ = memory.VirtualProtect(
        @as(*anyopaque, @ptrFromInt(present_slot_addr)),
        @sizeOf(PresentFn),
        old_protect,
        &restore_dummy,
    );

    _ = swap_chain.IUnknown.Release();
    _ = device.IUnknown.Release();
    _ = immediate_ctx.IUnknown.Release();
    return true;
}

fn uninstallPresentHook() bool {
    hook_mutex.lock();
    defer hook_mutex.unlock();

    const hook_slot = present_slot orelse {
        present_hook_installed.store(false, .release);
        return true;
    };
    const original = original_present orelse {
        log.err("Render unhook failed: original Present pointer is null", .{});
        return false;
    };

    const present_slot_addr = @intFromPtr(hook_slot);
    var old_protect: memory.PAGE_PROTECTION_FLAGS = undefined;
    if (memory.VirtualProtect(
        @as(*anyopaque, @ptrFromInt(present_slot_addr)),
        @sizeOf(PresentFn),
        memory.PAGE_EXECUTE_READWRITE,
        &old_protect,
    ) == 0) {
        log.err("Render unhook failed: VirtualProtect denied", .{});
        return false;
    }

    hook_slot.* = original;

    var restore_dummy: memory.PAGE_PROTECTION_FLAGS = undefined;
    _ = memory.VirtualProtect(
        @as(*anyopaque, @ptrFromInt(present_slot_addr)),
        @sizeOf(PresentFn),
        old_protect,
        &restore_dummy,
    );

    present_slot = null;
    present_hook_installed.store(false, .release);
    log.info("Render hook removed: IDXGISwapChain::Present", .{});
    return true;
}

fn hkPresent(self: *const dxgi.IDXGISwapChain, sync_interval: u32, flags: u32) callconv(.winapi) foundation.HRESULT {
    _ = active_present_calls.fetchAdd(1, .acq_rel);
    defer _ = active_present_calls.fetchSub(1, .acq_rel);

    if (!first_present_seen.swap(true, .acq_rel)) {
        log.info("Render hook active: first Present callback", .{});
    }

    const original = original_present orelse return 0;
    if (!shutdown_requested.load(.acquire)) {
        drawQueued(self);
    }
    return original(self, sync_interval, flags);
}

fn drawQueued(swap_chain: *const dxgi.IDXGISwapChain) void {
    var snapshot: [max_commands]DrawCommand = undefined;
    var snapshot_count: usize = 0;
    commands_mutex.lock();
    snapshot_count = command_count;
    std.mem.copyForwards(DrawCommand, snapshot[0..snapshot_count], commands[0..snapshot_count]);
    commands_mutex.unlock();
    if (snapshot_count == 0) return;

    var back_buffer_raw: *anyopaque = undefined;
    if (swap_chain.GetBuffer(0, d3d11.IID_ID3D11Texture2D, &back_buffer_raw) < 0) return;
    const back_buffer: *d3d11.ID3D11Texture2D = @ptrCast(@alignCast(back_buffer_raw));
    defer _ = back_buffer.IUnknown.Release();

    var back_buffer_desc: d3d11.D3D11_TEXTURE2D_DESC = undefined;
    back_buffer.GetDesc(&back_buffer_desc);

    const width: i32 = @intCast(back_buffer_desc.Width);
    const height: i32 = @intCast(back_buffer_desc.Height);
    if (width <= 0 or height <= 0) return;

    const device_subobject: *const dxgi.IDXGIDeviceSubObject = @ptrCast(swap_chain);
    var device_raw: *anyopaque = undefined;
    if (device_subobject.GetDevice(d3d11.IID_ID3D11Device, &device_raw) < 0) return;
    const device: *d3d11.ID3D11Device = @ptrCast(@alignCast(device_raw));
    defer _ = device.IUnknown.Release();

    const back_buffer_resource: *d3d11.ID3D11Resource = @ptrCast(back_buffer);
    var render_target_view: *d3d11.ID3D11RenderTargetView = undefined;
    if (device.CreateRenderTargetView(back_buffer_resource, null, &render_target_view) < 0) return;
    defer _ = render_target_view.IUnknown.Release();

    var immediate_ctx_opt: ?*d3d11.ID3D11DeviceContext = null;
    device.GetImmediateContext(&immediate_ctx_opt);
    const immediate_ctx = immediate_ctx_opt orelse return;
    defer _ = immediate_ctx.IUnknown.Release();

    var context1_raw: *anyopaque = undefined;
    if (immediate_ctx.IUnknown.QueryInterface(d3d11.IID_ID3D11DeviceContext1, &context1_raw) < 0) return;
    const context1: *d3d11.ID3D11DeviceContext1 = @ptrCast(@alignCast(context1_raw));
    defer _ = context1.IUnknown.Release();

    const target_view: *d3d11.ID3D11View = @ptrCast(render_target_view);

    var i: usize = 0;
    while (i < snapshot_count) : (i += 1) {
        switch (snapshot[i]) {
            .cross => |cross| drawCross(context1, target_view, width, height, cross.pos, cross.radius, cross.color),
            .box => |box| drawBox(context1, target_view, width, height, box.left, box.top, box.right, box.bottom, box.color),
        }
    }

    if (!first_draw_seen.swap(true, .acq_rel)) {
        log.info("Render draw path active: commands={d}, backbuffer={d}x{d}", .{ snapshot_count, width, height });
    }
}

fn drawCross(
    context1: *const d3d11.ID3D11DeviceContext1,
    target_view: *d3d11.ID3D11View,
    width: i32,
    height: i32,
    pos: Vec2,
    radius: i32,
    color: u32,
) void {
    const cx: i32 = @intFromFloat(@round(pos.x));
    const cy: i32 = @intFromFloat(@round(pos.y));

    clearRect(context1, target_view, width, height, cx - radius, cy, cx + radius + 1, cy + 1, color);
    clearRect(context1, target_view, width, height, cx, cy - radius, cx + 1, cy + radius + 1, color);
}

fn drawBox(
    context1: *const d3d11.ID3D11DeviceContext1,
    target_view: *d3d11.ID3D11View,
    width: i32,
    height: i32,
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
    color: u32,
) void {
    var l: i32 = @intFromFloat(@round(left));
    var t: i32 = @intFromFloat(@round(top));
    var r: i32 = @intFromFloat(@round(right));
    var b: i32 = @intFromFloat(@round(bottom));

    if (l > r) {
        const tmp = l;
        l = r;
        r = tmp;
    }
    if (t > b) {
        const tmp = t;
        t = b;
        b = tmp;
    }

    clearRect(context1, target_view, width, height, l, t, r + 1, t + 1, color);
    clearRect(context1, target_view, width, height, l, b, r + 1, b + 1, color);
    clearRect(context1, target_view, width, height, l, t, l + 1, b + 1, color);
    clearRect(context1, target_view, width, height, r, t, r + 1, b + 1, color);
}

fn clearRect(
    context1: *const d3d11.ID3D11DeviceContext1,
    target_view: *d3d11.ID3D11View,
    width: i32,
    height: i32,
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
    color: u32,
) void {
    var l = left;
    var t = top;
    var r = right;
    var b = bottom;

    if (l < 0) l = 0;
    if (t < 0) t = 0;
    if (r > width) r = width;
    if (b > height) b = height;
    if (l >= r or t >= b) return;

    var rect = foundation.RECT{
        .left = l,
        .top = t,
        .right = r,
        .bottom = b,
    };
    const rect_ptr: [*]const foundation.RECT = @ptrCast(&rect);

    var rgba = colorToRgba(color);
    context1.ClearView(target_view, &rgba[0], rect_ptr, 1);
}

fn colorToRgba(color: u32) [4]f32 {
    const rf: f32 = @floatFromInt(color & 0xFF);
    const gf: f32 = @floatFromInt((color >> 8) & 0xFF);
    const bf: f32 = @floatFromInt((color >> 16) & 0xFF);
    return .{
        rf / 255.0,
        gf / 255.0,
        bf / 255.0,
        1.0,
    };
}

fn resolveTargetWindow() ?foundation.HWND {
    const hwnd = windows_and_messaging.GetForegroundWindow() orelse return null;

    var window_pid: u32 = 0;
    _ = windows_and_messaging.GetWindowThreadProcessId(hwnd, &window_pid);
    if (window_pid != threading.GetCurrentProcessId()) return null;
    if (windows_and_messaging.IsWindowVisible(hwnd) == 0) return null;
    return hwnd;
}

fn rgb(r: u8, g: u8, b: u8) u32 {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16);
}
