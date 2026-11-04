//! Rembrandt: a small native image console for OpenAI-compatible backends.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const app_view = @import("app.zig");
const log = @import("log.zig");
const theme = @import("theme.zig");

/// Every `std.log` message, Rembrandt's and nanoui's, goes to the same file:
/// a GUI app's stderr is read by no one.
pub const std_options: std.Options = .{ .log_level = .info, .logFn = log.stdLog };

pub fn main(init: std.process.Init) !void {
    log.init(init);
    defer log.deinit();
    log.info("Rembrandt starting: {s} build, {s}", .{ @tagName(builtin.mode), @tagName(builtin.os.tag) });
    log.info("log file: {s}", .{log.filePath() orelse "stderr only"});

    const app = nanoui.App.create(init, .{ .name = "Rembrandt" }) catch |e| {
        log.err("App.create failed: {t}", .{e});
        return e;
    };
    defer app.destroy();

    var state = app_view.State.init(std.heap.c_allocator, init.io, init.environ_map) catch |e| {
        log.err("state init failed: {t}", .{e});
        return e;
    };
    defer state.deinit();

    const window = app.newWindow(.{
        .title = "Rembrandt",
        .width = 1240,
        .height = 820,
        .min_width = 1040,
        .min_height = 700,
        .title_bar = .hidden,
        .theme = theme.paper,
        .content = .{ .view = .init(&state, app_view.State.view) },
    }) catch |e| {
        log.err("newWindow failed: {t}", .{e});
        return e;
    };
    state.window = window;
    log.info("window created: 1240x820, custom header", .{});

    // The header is the title bar on Windows: take the system caption away,
    // keep the resize edges and the shadow, and set the window's icon.
    if (comptime builtin.os.tag == .windows) {
        const win_frame = @import("win_frame.zig");
        log.info("installing custom Windows frame", .{});
        if (window.surface) |surface| win_frame.setContext(&surface.ctx);
        win_frame.install(window.hwnd);
        log.info("custom Windows frame installed", .{});
    }

    log.info("event loop starting", .{});
    app.run() catch |e| {
        log.err("event loop failed: {t}", .{e});
        return e;
    };
    log.info("event loop returned", .{});
}
