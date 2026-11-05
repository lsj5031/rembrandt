//! Reads the GIFs the backend returns and composes their frames into small
//! PNGs: nanoui's image widget reads PNG off macOS, so the preview is built
//! from decoded frames instead of the GIF file itself.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

pub const max_frames: usize = 64;
pub const max_pixels: u64 = 16 * 1024 * 1024;

pub const Frame = struct {
    png: []u8,
    delay_ms: u16,
};

pub const Animation = struct {
    width: u32,
    height: u32,
    frames: []Frame,

    pub fn deinit(a: *Animation, gpa: std.mem.Allocator) void {
        for (a.frames) |f| gpa.free(f.png);
        gpa.free(a.frames);
        a.* = undefined;
    }
};

pub fn size(bytes: []const u8) ?struct { width: u32, height: u32 } {
    if (bytes.len < 10) return null;
    if (!std.mem.eql(u8, bytes[0..6], "GIF87a") and !std.mem.eql(u8, bytes[0..6], "GIF89a")) return null;
    const w = std.mem.readInt(u16, bytes[6..8], .little);
    const h = std.mem.readInt(u16, bytes[8..10], .little);
    if (w == 0 or h == 0) return null;
    return .{ .width = w, .height = h };
}

/// Composites every frame onto the logical screen and scales it to fit
/// `max_width` x `max_height`, encoding each one as PNG.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8, max_width: u32, max_height: u32) !Animation {
    if (bytes.len < 13) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..6], "GIF87a") and !std.mem.eql(u8, bytes[0..6], "GIF89a")) return error.NotGif;
    var r: Reader = .{ .bytes = bytes, .at = 6 };
    const width = try r.u16le();
    const height = try r.u16le();
    if (width == 0 or height == 0) return error.InvalidGif;
    if (@as(u64, width) * @as(u64, height) > max_pixels) return error.TooLarge;
    const w: usize = width;
    const h: usize = height;
    const screen_flags = try r.byte();
    const background_index = try r.byte();
    _ = try r.byte();
    const global: ?[]const u8 = if (screen_flags & 0x80 != 0) try r.table(screen_flags & 0x07) else null;
    const background = backgroundColor(global, background_index);

    const canvas = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(canvas);
    @memset(canvas, 0);

    var frames: std.ArrayList(Frame) = .empty;
    errdefer {
        for (frames.items) |f| gpa.free(f.png);
        frames.deinit(gpa);
    }
    var gce: Gce = .{};
    var previous: ?Previous = null;
    var saved: ?[]u8 = null;
    defer if (saved) |s| gpa.free(s);

    while (true) {
        const marker = try r.byte();
        switch (marker) {
            0x3B => break,
            0x21 => {
                const label = try r.byte();
                if (label == 0xF9) {
                    const block_size = try r.byte();
                    if (block_size != 4) return error.InvalidGif;
                    const control = try r.byte();
                    const delay = try r.u16le();
                    const transparent_index = try r.byte();
                    const terminator = try r.byte();
                    if (terminator != 0) return error.InvalidGif;
                    gce = .{
                        .disposal = (control >> 2) & 0x07,
                        .transparent = control & 0x01 != 0,
                        .transparent_index = transparent_index,
                        .delay_ms = delayMs(delay),
                    };
                } else {
                    try r.skipSubBlocks();
                }
            },
            0x2C => {
                const left = try r.u16le();
                const top = try r.u16le();
                const frame_width = try r.u16le();
                const frame_height = try r.u16le();
                const flags = try r.byte();
                if (frame_width == 0 or frame_height == 0) return error.InvalidGif;
                if (@as(u64, frame_width) * @as(u64, frame_height) > max_pixels) return error.TooLarge;
                if (frames.items.len >= max_frames) return error.TooManyFrames;
                const fw: usize = frame_width;
                const fh: usize = frame_height;
                const local: ?[]const u8 = if (flags & 0x80 != 0) try r.table(flags & 0x07) else null;
                const table = local orelse global orelse return error.InvalidGif;
                const interlaced = flags & 0x40 != 0;
                const min_code = try r.byte();
                if (min_code < 2 or min_code > 8) return error.InvalidGif;
                const compressed = try r.subBlocks(gpa);
                defer gpa.free(compressed);
                const indices = try gpa.alloc(u8, fw * fh);
                defer gpa.free(indices);
                try lzwDecode(compressed, min_code, indices);

                if (previous) |prev| {
                    switch (prev.disposal) {
                        2 => clearRect(canvas, w, h, prev, background),
                        3 => if (saved) |s| {
                            @memcpy(canvas, s);
                            gpa.free(s);
                            saved = null;
                        },
                        else => {},
                    }
                }
                const disposal = gce.disposal;
                if (disposal == 3) {
                    if (saved) |s| gpa.free(s);
                    saved = try gpa.dupe(u8, canvas);
                }

                var row_map: ?[]u16 = null;
                defer if (row_map) |m| gpa.free(m);
                if (interlaced) {
                    const map = try gpa.alloc(u16, fh);
                    var at: usize = 0;
                    for ([_][2]u16{ .{ 0, 8 }, .{ 4, 8 }, .{ 2, 4 }, .{ 1, 2 } }) |pass| {
                        var y: usize = pass[0];
                        while (y < fh) : (y += pass[1]) {
                            map[at] = @intCast(y);
                            at += 1;
                        }
                    }
                    row_map = map;
                }
                for (0..fh) |row| {
                    const dest_row: usize = if (row_map) |m| m[row] else row;
                    const y = @as(usize, top) + dest_row;
                    if (y >= h) continue;
                    for (0..fw) |x| {
                        const index = indices[row * fw + x];
                        if (gce.transparent and index == gce.transparent_index) continue;
                        const color = @as(usize, index) * 3;
                        if (color + 2 >= table.len) return error.InvalidGif;
                        const px = @as(usize, left) + x;
                        if (px >= w) continue;
                        const at = (y * w + px) * 4;
                        canvas[at] = table[color + 2];
                        canvas[at + 1] = table[color + 1];
                        canvas[at + 2] = table[color];
                        canvas[at + 3] = 255;
                    }
                }
                const png = try encodePreview(gpa, canvas, width, height, max_width, max_height);
                frames.append(gpa, .{ .png = png, .delay_ms = gce.delay_ms }) catch |e| {
                    gpa.free(png);
                    return e;
                };
                previous = .{ .disposal = disposal, .x = left, .y = top, .w = frame_width, .h = frame_height };
                gce = .{};
            },
            else => return error.InvalidGif,
        }
    }
    if (frames.items.len == 0) return error.NoFrames;
    return .{ .width = width, .height = height, .frames = try frames.toOwnedSlice(gpa) };
}

const Gce = struct {
    disposal: u8 = 0,
    transparent: bool = false,
    transparent_index: u8 = 0,
    delay_ms: u16 = 100,
};

const Previous = struct {
    disposal: u8,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
};

fn delayMs(centiseconds: u16) u16 {
    if (centiseconds == 0) return 100;
    return @intCast(@min(@max(@as(u32, centiseconds) * 10, 20), 60_000));
}

/// The logical screen's background color in the canvas's BGRA order. Without
/// a global color table there is no background color, so the area is cleared
/// to transparent instead.
fn backgroundColor(global: ?[]const u8, index: u8) [4]u8 {
    const table = global orelse return .{ 0, 0, 0, 0 };
    const at = @as(usize, index) * 3;
    if (at + 2 >= table.len) return .{ 0, 0, 0, 0 };
    return .{ table[at + 2], table[at + 1], table[at], 255 };
}

/// Disposal method 2: restore the frame's rectangle to the logical screen
/// background color, not to transparency.
fn clearRect(canvas: []u8, width: usize, height: usize, rect: Previous, background: [4]u8) void {
    const x0 = @min(@as(usize, rect.x), width);
    const y0 = @min(@as(usize, rect.y), height);
    const x1 = @min(@as(usize, rect.x) + rect.w, width);
    const y1 = @min(@as(usize, rect.y) + rect.h, height);
    for (y0..y1) |y| for (x0..x1) |x| {
        @memcpy(canvas[(y * width + x) * 4 ..][0..4], &background);
    };
}

/// Nearest-neighbour, sized to the preview: full frames would be tens of
/// megabytes of stored PNG per result.
fn encodePreview(gpa: std.mem.Allocator, canvas: []const u8, width: u32, height: u32, max_width: u32, max_height: u32) ![]u8 {
    const w: usize = width;
    const h: usize = height;
    const mw: usize = @max(max_width, 1);
    const mh: usize = @max(max_height, 1);
    var tw: usize = @min(w, mw);
    var th: usize = @max(1, (h * tw + w / 2) / w);
    if (th > mh) {
        th = mh;
        tw = @max(1, (w * th + h / 2) / h);
    }
    const pixels = try gpa.alloc(u8, tw * th * 4);
    defer gpa.free(pixels);
    for (0..th) |y| {
        const sy = @min(h - 1, y * h / th);
        for (0..tw) |x| {
            const sx = @min(w - 1, x * w / tw);
            const src = (sy * w + sx) * 4;
            const dst = (y * tw + x) * 4;
            pixels[dst..][0..4].* = canvas[src..][0..4].*;
        }
    }
    return ui.png.encode(gpa, .{ .bytes = pixels, .width = @intCast(tw), .height = @intCast(th) });
}

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn byte(r: *Reader) !u8 {
        if (r.at >= r.bytes.len) return error.Truncated;
        const b = r.bytes[r.at];
        r.at += 1;
        return b;
    }

    fn u16le(r: *Reader) !u16 {
        const lo = try r.byte();
        const hi = try r.byte();
        return @as(u16, lo) | (@as(u16, hi) << 8);
    }

    fn skip(r: *Reader, n: usize) !void {
        if (n > r.bytes.len - r.at) return error.Truncated;
        r.at += n;
    }

    fn table(r: *Reader, bits: u8) ![]const u8 {
        const count = @as(usize, 1) << @intCast(bits + 1);
        const start = r.at;
        try r.skip(count * 3);
        return r.bytes[start..r.at];
    }

    fn subBlocks(r: *Reader, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        while (true) {
            const n = try r.byte();
            if (n == 0) break;
            const start = r.at;
            try r.skip(n);
            try out.appendSlice(gpa, r.bytes[start..r.at]);
        }
        return out.toOwnedSlice(gpa);
    }

    fn skipSubBlocks(r: *Reader) !void {
        while (true) {
            const n = try r.byte();
            if (n == 0) break;
            try r.skip(n);
        }
    }
};

/// GIF's variable-width LZW, writing exactly `out.len` palette indices.
fn lzwDecode(data: []const u8, min_code: u8, out: []u8) !void {
    const clear: u16 = @as(u16, 1) << @intCast(min_code);
    const end: u16 = clear + 1;
    var prefix: [4096]u16 = undefined;
    var suffix: [4096]u8 = undefined;
    var stack: [4096]u8 = undefined;
    for (0..clear) |i| {
        prefix[i] = 0;
        suffix[i] = @intCast(i);
    }
    var next: u16 = clear + 2;
    var code_size: u4 = @intCast(min_code + 1);
    var code_mask: u16 = (@as(u16, 1) << code_size) - 1;
    var datum: u32 = 0;
    var bits: u5 = 0;
    var pos: usize = 0;
    var written: usize = 0;
    var old: ?u16 = null;
    var first: u8 = 0;

    while (written < out.len) {
        while (bits < code_size) {
            if (pos >= data.len) return error.Truncated;
            datum |= @as(u32, data[pos]) << bits;
            pos += 1;
            bits += 8;
        }
        var code: u16 = @intCast(datum & code_mask);
        datum >>= code_size;
        bits -= code_size;

        if (code == clear) {
            code_size = @intCast(min_code + 1);
            code_mask = (@as(u16, 1) << code_size) - 1;
            next = clear + 2;
            old = null;
            continue;
        }
        if (code == end) return error.Truncated;
        if (old == null) {
            if (code >= clear) return error.InvalidGif;
            out[written] = @intCast(code);
            written += 1;
            first = @intCast(code);
            old = code;
            continue;
        }

        const in_code = code;
        var depth: usize = 0;
        if (code >= next) {
            if (code != next) return error.InvalidGif;
            stack[depth] = first;
            depth += 1;
            code = old.?;
        }
        while (code >= clear) {
            if (depth >= stack.len) return error.InvalidGif;
            stack[depth] = suffix[code];
            depth += 1;
            code = prefix[code];
        }
        first = @intCast(code);
        if (depth >= stack.len) return error.InvalidGif;
        stack[depth] = first;
        depth += 1;
        while (depth > 0) {
            depth -= 1;
            if (written >= out.len) return error.Truncated;
            out[written] = stack[depth];
            written += 1;
        }
        if (next < 4096) {
            prefix[next] = old.?;
            suffix[next] = first;
            next += 1;
            if (next == (@as(u16, 1) << code_size) and code_size < 12) {
                code_size += 1;
                code_mask = (@as(u16, 1) << code_size) - 1;
            }
        }
        old = in_code;
    }
}

test "a two-frame GIF becomes two PNG frames with its delays" {
    const gpa = std.testing.allocator;
    const bytes = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        1,   0,   1,   0,   0x80, 0,   0,
        0,   0,   0,   255, 255, 255,
        0x21, 0xF9, 0x04, 0x00, 5, 0, 0, 0,
        0x2C, 0,    0,    0,    0, 1, 0, 1, 0, 0x00,
        2,    2,    0x44, 0x01, 0,
        0x21, 0xF9, 0x04, 0x00, 5, 0, 0, 0,
        0x2C, 0,    0,    0,    0, 1, 0, 1, 0, 0x00,
        2,    2,    0x44, 0x01, 0,
        0x3B,
    };
    var anim = try decode(gpa, &bytes, 700, 467);
    defer anim.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 1), anim.width);
    try std.testing.expectEqual(@as(usize, 2), anim.frames.len);
    try std.testing.expectEqual(@as(u16, 50), anim.frames[0].delay_ms);
    try std.testing.expectEqual(@as(u16, 50), anim.frames[1].delay_ms);
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\n", anim.frames[0].png[0..8]);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, anim.frames[1].png[16..20], .big));
}

test "disposal to background restores the logical screen color" {
    const table = [_]u8{ 0, 0, 0, 255, 0, 0, 0, 255, 0 };
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, backgroundColor(null, 1));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, backgroundColor(&table, 1));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, backgroundColor(&table, 3));

    var canvas: [3 * 2 * 4]u8 = @splat(0);
    clearRect(&canvas, 3, 2, .{ .disposal = 2, .x = 1, .y = 0, .w = 2, .h = 2 }, backgroundColor(&table, 1));
    for (0..2) |y| {
        try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, canvas[(y * 3) * 4 ..][0..4].*);
        for (1..3) |x| try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, canvas[(y * 3 + x) * 4 ..][0..4].*);
    }
}

test "a truncated GIF is rejected" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.Truncated, decode(gpa, "GIF89a\x01", 700, 467));
    try std.testing.expectError(error.NotGif, decode(gpa, "not a gif at all", 700, 467));
    try std.testing.expect(size("GIF89a\x01\x00\x01\x00") != null);
}
