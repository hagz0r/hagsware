const dumper = @import("dumper/mod.zig");
const win32 = @import("win32");
const library_loader = win32.system.library_loader;

pub const GameContext = struct {
    client_base: usize,
    engine2_base: usize,

    pub fn init() !GameContext {
        const client = library_loader.GetModuleHandleA("client.dll") orelse return error.ClientModuleNotFound;
        const engine2 = library_loader.GetModuleHandleA("engine2.dll") orelse return error.Engine2ModuleNotFound;

        return .{
            .client_base = @intFromPtr(client),
            .engine2_base = @intFromPtr(engine2),
        };
    }
};

pub const AppContext = struct {
    db: *dumper.Database,
    game: GameContext,
};
