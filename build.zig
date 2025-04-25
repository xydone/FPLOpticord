const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("fplopticord", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "fplopticord",
        .root_module = module,
    });
    const discordzig = b.dependency("discordzig", .{});
    const zdt = b.dependency("zdt", .{
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("discordzig", discordzig.module("discord.zig"));
    exe.root_module.addImport("zdt", zdt.module("zdt"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_unit_tests = b.addTest(.{
        .root_module = module,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Test code with custom test runner");
    test_step.dependOn(&run_exe_unit_tests.step);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_check = b.addExecutable(.{
        .name = "fplopticord",
        .root_module = module,
    });
    const check = b.step("check", "Check if fplopticord compiles");
    check.dependOn(&exe_check.step);
}
