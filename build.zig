const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zigwin32 = b.dependency("zigwin32", .{});
    const win32_mod = zigwin32.module("win32");

    const mod = b.addModule("hagsware", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "win32", .module = win32_mod },
        },
    });

    const dll = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "hagsware",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hagsware", .module = mod },
                .{ .name = "win32", .module = win32_mod },
            },
        }),
    });

    b.installArtifact(dll);

    const loader = b.addExecutable(.{
        .name = "hagsware_loader",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/loader.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "win32", .module = win32_mod },
            },
        }),
    });
    b.installArtifact(loader);

    const loader_run_step = b.step("loader-run", "Run DLL self_test via loader");
    const loader_run_cmd = b.addRunArtifact(loader);
    loader_run_cmd.step.dependOn(b.getInstallStep());
    loader_run_step.dependOn(&loader_run_cmd.step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const dll_tests = b.addTest(.{
        .root_module = dll.root_module,
    });

    const run_dll_tests = b.addRunArtifact(dll_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_dll_tests.step);
}
