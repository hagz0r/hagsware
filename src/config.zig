const std = @import("std");
const win32 = @import("win32");
const log = @import("log.zig");

const foundation = win32.foundation;
const library_loader = win32.system.library_loader;
const allocator = std.heap.page_allocator;

const config_file_name = "hagsware.toml";
const max_config_size = 64 * 1024;

pub const Settings = struct {
    esp: Esp = .{},

    pub const Esp = struct {
        enabled: bool = true,
        draw_box: bool = true,
        box_thickness: i32 = 2,
        draw_center_cross: bool = true,
        draw_name: bool = false,
        draw_weapon: bool = false,
        enemy_color: u32 = rgb(255, 64, 64),
        friendly_color: u32 = rgb(64, 192, 255),
        debug_color: u32 = rgb(255, 255, 255),
    };
};

var settings: Settings = .{};
var warned_unsupported_text = std.atomic.Value(bool).init(false);
var last_config_mtime: i128 = -1;

pub fn load(module: ?foundation.HINSTANCE) void {
    settings = .{};
    last_config_mtime = -1;
    reloadInternal(module, true);
}

pub fn reloadIfChanged(module: ?foundation.HINSTANCE) void {
    reloadInternal(module, false);
}

pub fn get() Settings {
    return settings;
}

pub fn warnTextSettingsIfNeeded() void {
    const esp = settings.esp;
    if (!esp.draw_name and !esp.draw_weapon) return;
    if (warned_unsupported_text.swap(true, .acq_rel)) return;

    log.info(
        "Config: draw_name/draw_weapon enabled, but text rendering is not implemented in current internal renderer",
        .{},
    );
}

fn resolveConfigPath(module: ?foundation.HINSTANCE) ![]u8 {
    if (module == null) {
        return allocator.dupe(u8, config_file_name);
    }

    var module_path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const len_u32 = library_loader.GetModuleFileNameA(
        module,
        @as([*:0]u8, @ptrCast(&module_path_buf)),
        @intCast(module_path_buf.len),
    );
    if (len_u32 == 0 or len_u32 >= module_path_buf.len) {
        return error.ModulePathUnavailable;
    }

    const len: usize = @intCast(len_u32);
    const module_path = module_path_buf[0..len];
    const module_dir = std.fs.path.dirname(module_path) orelse ".";
    return std.fs.path.join(allocator, &.{ module_dir, config_file_name });
}

fn readConfig(file: *std.fs.File) ![]u8 {
    try file.seekTo(0);
    return file.readToEndAlloc(allocator, max_config_size);
}

fn openAndStatConfig(path: []const u8) !struct {
    file: std.fs.File,
    mtime: i128,
} {
    var file = try openFileForRead(path);
    const stat = try file.stat();
    return .{
        .file = file,
        .mtime = stat.mtime,
    };
}

fn reloadInternal(module: ?foundation.HINSTANCE, initial: bool) void {
    const config_path = resolveConfigPath(module) catch |err| {
        if (initial) log.err("Config path resolve failed: {s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(config_path);

    var opened = openAndStatConfig(config_path) catch |err| {
        if (initial) log.err("Config read failed: {s}, path={s}", .{ @errorName(err), config_path });
        return;
    };
    defer opened.file.close();

    if (!initial and opened.mtime == last_config_mtime) return;

    const file_data = readConfig(&opened.file) catch |err| {
        if (initial) log.err("Config read failed: {s}, path={s}", .{ @errorName(err), config_path });
        return;
    };
    defer allocator.free(file_data);

    settings = parseConfig(file_data);
    last_config_mtime = opened.mtime;
    _ = warned_unsupported_text.swap(false, .acq_rel);

    if (initial) {
        log.info("Config loaded: {s}", .{config_path});
    } else {
        log.info("Config reloaded: {s}", .{config_path});
    }
    log.info(
        "Config ESP: enabled={any}, draw_box={any}, thickness={d}, center_cross={any}, draw_name={any}, draw_weapon={any}",
        .{
            settings.esp.enabled,
            settings.esp.draw_box,
            settings.esp.box_thickness,
            settings.esp.draw_center_cross,
            settings.esp.draw_name,
            settings.esp.draw_weapon,
        },
    );
}

fn openFileForRead(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openFileAbsolute(path, .{});
    }
    return std.fs.cwd().openFile(path, .{});
}

fn parseConfig(input: []const u8) Settings {
    var out = Settings{};
    var section: []const u8 = "";
    var line_number: usize = 0;

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line_raw| {
        line_number += 1;
        var line = std.mem.trimRight(u8, line_raw, "\r");
        line = stripComment(line);
        line = std.mem.trim(u8, line, " \t");
        if (line.len == 0) continue;

        if (line[0] == '[' and line[line.len - 1] == ']') {
            section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            log.err("Config parse: missing '=' at line {d}", .{line_number});
            continue;
        };

        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) continue;

        if (std.mem.eql(u8, section, "esp")) {
            applyEspSetting(&out, key, value, line_number);
        }
    }

    return out;
}

fn applyEspSetting(out: *Settings, key: []const u8, value: []const u8, line_number: usize) void {
    if (std.mem.eql(u8, key, "enabled")) {
        if (parseBool(value)) |v| out.esp.enabled = v else logInvalid(key, line_number);
        return;
    }
    if (std.mem.eql(u8, key, "draw_box")) {
        if (parseBool(value)) |v| out.esp.draw_box = v else logInvalid(key, line_number);
        return;
    }
    if (std.mem.eql(u8, key, "box_thickness")) {
        if (parseI32(value)) |v| out.esp.box_thickness = std.math.clamp(v, 1, 8) else logInvalid(key, line_number);
        return;
    }
    if (std.mem.eql(u8, key, "draw_center_cross")) {
        if (parseBool(value)) |v| out.esp.draw_center_cross = v else logInvalid(key, line_number);
        return;
    }
    if (std.mem.eql(u8, key, "draw_name")) {
        if (parseBool(value)) |v| out.esp.draw_name = v else logInvalid(key, line_number);
        return;
    }
    if (std.mem.eql(u8, key, "draw_weapon")) {
        if (parseBool(value)) |v| out.esp.draw_weapon = v else logInvalid(key, line_number);
        return;
    }
    if (std.mem.eql(u8, key, "enemy_color")) {
        if (parseColor(value)) |v| out.esp.enemy_color = v else logInvalid(key, line_number);
        return;
    }
    if (std.mem.eql(u8, key, "friendly_color")) {
        if (parseColor(value)) |v| out.esp.friendly_color = v else logInvalid(key, line_number);
        return;
    }
    if (std.mem.eql(u8, key, "debug_color")) {
        if (parseColor(value)) |v| out.esp.debug_color = v else logInvalid(key, line_number);
        return;
    }
}

fn parseBool(raw: []const u8) ?bool {
    const value = unquote(raw);
    if (std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    return null;
}

fn parseI32(raw: []const u8) ?i32 {
    const value = unquote(raw);
    return std.fmt.parseInt(i32, value, 0) catch null;
}

fn parseColor(raw: []const u8) ?u32 {
    var value = unquote(raw);
    if (value.len == 0) return null;
    if (value[0] == '#') value = value[1..];

    var rrggbb: u32 = 0;
    if (std.mem.startsWith(u8, value, "0x") or std.mem.startsWith(u8, value, "0X")) {
        rrggbb = std.fmt.parseInt(u32, value, 0) catch return null;
    } else if (value.len == 6) {
        rrggbb = std.fmt.parseInt(u32, value, 16) catch return null;
    } else {
        rrggbb = std.fmt.parseInt(u32, value, 10) catch return null;
    }

    return rrggbbToColorRef(rrggbb);
}

fn rrggbbToColorRef(rrggbb: u32) u32 {
    const r = (rrggbb >> 16) & 0xFF;
    const g = (rrggbb >> 8) & 0xFF;
    const b = rrggbb & 0xFF;
    return rgb(@intCast(r), @intCast(g), @intCast(b));
}

fn unquote(raw: []const u8) []const u8 {
    const value = std.mem.trim(u8, raw, " \t");
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn stripComment(line: []const u8) []const u8 {
    var in_quotes = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '"') in_quotes = !in_quotes;
        if (!in_quotes and (c == '#' or c == ';')) {
            return line[0..i];
        }
    }
    return line;
}

fn logInvalid(key: []const u8, line_number: usize) void {
    log.err("Config parse: invalid value for '{s}' at line {d}", .{ key, line_number });
}

fn rgb(r: u8, g: u8, b: u8) u32 {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16);
}
