const std = @import("std");
const win32 = @import("win32");

const dbg = win32.system.diagnostics.debug;
const foundation = win32.foundation;
const system_information = win32.system.system_information;
const threading = win32.system.threading;
const allocator = std.heap.page_allocator;
const log_file_name = "hagsware.log";
var session_header_written = std.atomic.Value(bool).init(false);

pub fn info(comptime fmt: []const u8, args: anytype) void {
    write("INFO", fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    write("ERROR", fmt, args);
}

fn write(comptime level: []const u8, comptime fmt: []const u8, args: anytype) void {
    var msg_buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch return;

    ensureSessionHeader();

    const tid = threading.GetCurrentThreadId();
    const local_time = getLocalTime();

    var line_buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(
        &line_buf,
        "[{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}] [TID:{d}] {s}: {s}\r\n",
        .{
            local_time.wYear,
            local_time.wMonth,
            local_time.wDay,
            local_time.wHour,
            local_time.wMinute,
            local_time.wSecond,
            local_time.wMilliseconds,
            tid,
            level,
            msg,
        },
    ) catch return;

    writeDebug(line);
    appendToFile(line);
}

fn ensureSessionHeader() void {
    if (session_header_written.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
        return;
    }

    const pid = threading.GetCurrentProcessId();
    const local_time = getLocalTime();

    var header_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buf,
        "===== [PID:{d}] SESSION START [{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}] =====\r\n",
        .{
            pid,
            local_time.wYear,
            local_time.wMonth,
            local_time.wDay,
            local_time.wHour,
            local_time.wMinute,
            local_time.wSecond,
            local_time.wMilliseconds,
        },
    ) catch return;

    writeDebug(header);
    appendToFile(header);
}

fn getLocalTime() foundation.SYSTEMTIME {
    var local_time: foundation.SYSTEMTIME = undefined;
    system_information.GetLocalTime(&local_time);
    return local_time;
}

fn writeDebug(line: []const u8) void {
    var debug_buf: [1024:0]u8 = undefined;
    const debug_line = std.fmt.bufPrintZ(&debug_buf, "{s}", .{line}) catch return;
    dbg.OutputDebugStringA(debug_line.ptr);
}

fn appendToFile(line: []const u8) void {
    const path = getLogPath() catch return;
    defer allocator.free(path);

    var file = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
    defer file.close();

    file.seekFromEnd(0) catch return;
    file.writeAll(line) catch return;
}

fn getLogPath() ![]u8 {
    const temp_dir = std.process.getEnvVarOwned(allocator, "TEMP") catch |get_env_err| switch (get_env_err) {
        error.EnvironmentVariableNotFound => return allocator.dupe(u8, "C:\\Windows\\Temp\\hagsware.log"),
        else => return get_env_err,
    };
    defer allocator.free(temp_dir);

    return std.fs.path.join(allocator, &.{ temp_dir, log_file_name });
}
