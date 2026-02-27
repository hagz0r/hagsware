const std = @import("std");
const win = @cImport({
    @cInclude("windows.h");
    @cInclude("processthreadsapi.h");
    @cInclude("tlhelp32.h");
});
const hagsware = @import("hagsware");

pub fn main() !void {
    const pid = get_pid_from_name("cs2.exe");
    std.log.debug("Process ID: {}", .{pid});
}

pub fn get_pid_from_name(target_process_name: []const u8) win.PROCESSENTRY32W {
    const snapshot = win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS, 0);
    defer win.CloseHandle(snapshot);

    var process_entry: win.PROCESSENTRY32W = undefined;
    process_entry.dwSize = @sizeOf(win.PROCESSENTRY32W);

    if (win.Process32First(snapshot, &process_entry)) {
        while (win.Process32Next(snapshot, &process_entry)) {
            const process_name = std.mem.span(process_entry.szExeFile);
            if (std.mem.eql(u16, process_name, target_process_name)) {
                std.log.debug("Found process ID: {}", .{process_entry.th32ProcessID});
                return process_entry.th32ProcessID;
            }
        }
    }
}
