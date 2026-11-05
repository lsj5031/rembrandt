//! Plays the selected GIF in the preview: one decode per result, frames
//! stepped by their own delays, and nothing retained for other results.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const gif = @import("gif.zig");
const backend = @import("backend.zig");

pub const max_width: u32 = 700;
pub const max_height: u32 = 467;

pub const Playback = struct {
    name: ?[]u8 = null,
    frames: []gif.Frame = &.{},
    failed: bool = false,
    index: usize = 0,
    started: f64 = 0,

    pub fn deinit(p: *Playback, gpa: std.mem.Allocator) void {
        p.clear(gpa);
    }

    /// Keeps the playback for the selected item, decoding it once. Called
    /// before the view is laid out so a selection change takes effect now.
    pub fn sync(p: *Playback, gpa: std.mem.Allocator, item: ?*const backend.Item, now: f64) void {
        const want: ?[]const u8 = if (item) |it| (if (it.kind == .gif) it.name else null) else null;
        if (p.name) |name| {
            if (want != null and std.mem.eql(u8, name, want.?)) return;
            p.clear(gpa);
        }
        const it = item orelse return;
        if (it.kind != .gif) return;
        const owned = gpa.dupe(u8, it.name) catch return;
        p.name = owned;
        p.started = now;
        const anim = gif.decode(gpa, it.bytes, max_width, max_height) catch {
            p.failed = true;
            return;
        };
        p.frames = anim.frames;
        p.index = 0;
    }

    /// Draws the current frame; false when there is nothing to preview.
    pub fn draw(p: *Playback, c: *ui.Context, it: *const backend.Item) bool {
        if (p.failed or p.frames.len == 0) return false;
        if (p.name == null or !std.mem.eql(u8, p.name.?, it.name)) return false;
        if (p.frames.len > 1) {
            c.animationFrame();
            p.advance(ui.clock.now());
        }
        return ui.image(c, .{
            .key = c.print("{s}#{d}", .{ it.name, p.index }),
            .bytes = p.frames[p.index].png,
            .max_width = max_width,
            .max_height = max_height,
            .radius = 12,
            .scale = 1,
        });
    }

    fn advance(p: *Playback, now: f64) void {
        var total: f64 = 0;
        for (p.frames) |f| total += @as(f64, @floatFromInt(f.delay_ms)) / 1000.0;
        if (total <= 0) return;
        var remaining = @mod(now - p.started, total);
        if (remaining < 0) remaining = 0;
        p.index = 0;
        while (p.index + 1 < p.frames.len) {
            const delay = @as(f64, @floatFromInt(p.frames[p.index].delay_ms)) / 1000.0;
            if (remaining < delay) break;
            remaining -= delay;
            p.index += 1;
        }
    }

    fn clear(p: *Playback, gpa: std.mem.Allocator) void {
        if (p.name) |name| gpa.free(name);
        for (p.frames) |f| gpa.free(f.png);
        if (p.frames.len > 0) gpa.free(p.frames);
        p.* = .{};
    }
};
