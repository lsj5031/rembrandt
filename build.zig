const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");

    const exe = b.addExecutable(.{ .name = "rembrandt", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    // Explorer's, the taskbar's and Alt-Tab's icon comes from the exe's own
    // resources; win_frame.zig sets the window's from the same.
    if (target.result.os.tag == .windows) {
        exe.root_module.addWin32ResourceFile(.{ .file = b.path("assets/rembrandt.rc") });
        exe.subsystem = .windows;
    }
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run Rembrandt (opens its window)").dependOn(&run.step);

    // Tests render the view offscreen with ui.Tester: no window opens.
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);
}
