const std = @import("std");
const dumper = @import("dumper/mod.zig");
const AppContext = @import("app_context.zig").AppContext;
const generated = @import("hacks_autogen.zig");

pub const Hack = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        init: *const fn (ctx: *anyopaque) anyerror!void,
        update: *const fn (ctx: *anyopaque) anyerror!void,
    };

    pub fn from(comptime T: type, obj: *T) Hack {
        comptime {
            if (!@hasDecl(T, "init") or !@hasDecl(T, "update")) {
                @compileError(@typeName(T) ++ " must implement init/update");
            }
        }

        const Adapter = struct {
            fn callInit(ctx: *anyopaque) anyerror!void {
                const self: *T = @ptrCast(@alignCast(ctx));
                try self.init();
            }

            fn callUpdate(ctx: *anyopaque) anyerror!void {
                const self: *T = @ptrCast(@alignCast(ctx));
                try self.update();
            }

            const vtable = VTable{
                .init = callInit,
                .update = callUpdate,
            };
        };

        return .{
            .ctx = obj,
            .vtable = &Adapter.vtable,
        };
    }

    pub fn init(self: Hack) !void {
        try self.vtable.init(self.ctx);
    }

    pub fn update(self: Hack) !void {
        try self.vtable.update(self.ctx);
    }
};

pub const Registry = struct {
    app: AppContext,
    storage: generated.Storage,
    hacks: [generated.hack_count]Hack,

    pub fn init(self: *Registry, db: *dumper.Database) void {
        self.app = .{ .db = db };
        generated.initStorage(&self.storage, &self.app);

        inline for (std.meta.fields(generated.Storage), 0..) |field, index| {
            self.hacks[index] = Hack.from(field.type, &@field(self.storage, field.name));
        }
    }

    pub fn initAll(self: *Registry) !void {
        for (self.hacks) |hack| {
            try hack.init();
        }
    }

    pub fn updateAll(self: *Registry) !void {
        for (self.hacks) |hack| {
            try hack.update();
        }
    }
};
