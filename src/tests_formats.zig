//! Format tests: GIF/SVG requests, response sniffing, playback and saving.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("app.zig");
const backend = @import("backend.zig");
const generation = @import("generation.zig");
const gif = @import("gif.zig");

const gif_bytes = [_]u8{
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

const svg_bytes = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"12\" height=\"8\"><rect width=\"12\" height=\"8\"/></svg>";
const png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";

fn base64(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const out = try gpa.alloc(u8, encoder.calcSize(bytes.len));
    _ = encoder.encode(out, bytes);
    return out;
}

test "GIF and SVG requests carry their format fields" {
    const gpa = std.testing.allocator;
    var cfg = try backend.Config.defaults(gpa);
    defer cfg.deinit(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    cfg.format = .gif;
    cfg.frames = 12;
    cfg.frame_ms = 150;
    const gif_body = try backend.buildBody(gpa, &cfg, "p");
    defer gpa.free(gif_body);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, gif_body, .{});
    try std.testing.expectEqualStrings("gif", parsed.object.get("output_format").?.string);
    try std.testing.expectEqual(@as(i64, 12), parsed.object.get("frame_count").?.integer);
    try std.testing.expectEqual(@as(i64, 150), parsed.object.get("frame_duration_ms").?.integer);

    cfg.format = .svg;
    const svg_body = try backend.buildBody(gpa, &cfg, "p");
    defer gpa.free(svg_body);
    const svg_root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, svg_body, .{});
    try std.testing.expectEqualStrings("svg", svg_root.object.get("output_format").?.string);
    try std.testing.expect(svg_root.object.get("frame_count") == null);

    cfg.format = .png;
    const png_body = try backend.buildBody(gpa, &cfg, "p");
    defer gpa.free(png_body);
    const png_root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, png_body, .{});
    try std.testing.expect(png_root.object.get("output_format") == null);

    cfg.format = .gif;
    const inputs = [_]backend.RefInput{.{ .bytes = "\x89PNG\r\n\x1a\n", .mime = "image/png" }};
    const edit = try backend.buildEditBody(gpa, &cfg, "p", &inputs);
    defer gpa.free(edit);
    const edit_root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, edit, .{});
    try std.testing.expectEqualStrings("gif", edit_root.object.get("output_format").?.string);
}

test "responses are sniffed and sized by their real format" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(backend.Format.png, backend.sniffFormat("\x89PNG\r\n\x1a\n....").?);
    try std.testing.expectEqual(backend.Format.gif, backend.sniffFormat(&gif_bytes).?);
    try std.testing.expectEqual(backend.Format.svg, backend.sniffFormat(svg_bytes).?);
    try std.testing.expect(backend.sniffFormat("not an image") == null);
    try std.testing.expectEqual(@as(u32, 1), backend.gifSize(&gif_bytes).?.width);
    try std.testing.expectEqual(@as(u32, 12), backend.svgSize(svg_bytes).?.width);
    try std.testing.expectEqual(@as(u32, 8), backend.svgSize(svg_bytes).?.height);
    const name = try backend.fileName(gpa, 7, .gif);
    defer gpa.free(name);
    try std.testing.expectEqualStrings("rembrandt-7.gif", name);

    const gif_b64 = try base64(gpa, &gif_bytes);
    defer gpa.free(gif_b64);
    const image = try backend.decodeInline(gpa, gif_b64);
    defer gpa.free(image.bytes);
    try std.testing.expectEqual(backend.Format.gif, image.kind);
    try std.testing.expectEqualSlices(u8, &gif_bytes, image.bytes);

    const svg_b64 = try base64(gpa, svg_bytes);
    defer gpa.free(svg_b64);
    const vector = try backend.decodeInline(gpa, svg_b64);
    defer gpa.free(vector.bytes);
    try std.testing.expectEqual(backend.Format.svg, vector.kind);
    try std.testing.expectEqual(@as(u32, 12), vector.width);

    const still = try backend.decodeInline(gpa, png_b64);
    defer gpa.free(still.bytes);
    try std.testing.expectEqual(backend.Format.png, still.kind);
    try std.testing.expectError(error.NotAnImage, backend.decodeInline(gpa, "bm90IGFuIGltYWdl"));
}

test "a selected GIF decodes into the preview without a window" {
    const gpa = std.testing.allocator;
    var state = try app_view.State.initDefault(gpa, std.testing.io);
    defer state.deinit();
    state.addItem(.{
        .bytes = try gpa.dupe(u8, &gif_bytes),
        .name = try gpa.dupe(u8, "clip.gif"),
        .path = try gpa.dupe(u8, "clip.gif"),
        .width = 1,
        .height = 1,
        .tokens = 0,
        .secs = 0,
        .kind = .gif,
    });
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1240, .height = 820 });
    defer t.deinit();
    t.frame();
    try std.testing.expectEqual(@as(usize, 2), state.playback.frames.len);
    try std.testing.expect(state.playback.frames[0].png.len > 8);
}

test "GIF and SVG results save with their own extension and bytes" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(directory);
    var state = try app_view.State.initDefault(gpa, std.testing.io);
    defer state.deinit();
    state.output_dir = directory;

    const gif_name = try backend.fileName(gpa, 11, .gif);
    defer gpa.free(gif_name);
    try std.testing.expectEqualStrings("rembrandt-11.gif", gif_name);
    const gif_path = try generation.saveImage(&state, gif_name, &gif_bytes);
    defer gpa.free(gif_path);
    const saved = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, gif_path, gpa, .limited(1024));
    defer gpa.free(saved);
    try std.testing.expectEqualSlices(u8, &gif_bytes, saved);

    const svg_name = try backend.fileName(gpa, 12, .svg);
    defer gpa.free(svg_name);
    const svg_path = try generation.saveImage(&state, svg_name, svg_bytes);
    defer gpa.free(svg_path);
    const saved_svg = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, svg_path, gpa, .limited(1024));
    defer gpa.free(saved_svg);
    try std.testing.expectEqualStrings(svg_bytes, saved_svg);
}

test "the Backend sheet switches format and reveals GIF frames" {
    var state = try app_view.State.initDefault(std.testing.allocator, std.testing.io);
    defer state.deinit();
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&state, app_view.State.view), .{ .width = 1240, .height = 820 });
    defer t.deinit();
    t.settle(0.2);
    try t.clickText("server default");
    t.settle(0.2);
    try std.testing.expect(t.hasText("output: png"));
    try t.clickText("output: png");
    t.settle(0.1);
    try std.testing.expectEqual(backend.Format.gif, state.request_draft.format);
    try std.testing.expectEqual(backend.Format.png, state.config.format);
    try std.testing.expect(t.hasText("frames: 9"));
    try t.clickText("frames: 9");
    t.settle(0.1);
    try std.testing.expectEqual(@as(u8, 12), state.request_draft.frames);
    try t.clickText("output: gif");
    t.settle(0.1);
    try std.testing.expectEqual(backend.Format.svg, state.request_draft.format);
    try std.testing.expect(!t.hasText("frames: 12"));
    try t.clickText("Save");
    t.settle(0.1);
    try std.testing.expectEqual(backend.Format.svg, state.config.format);
    try std.testing.expectEqual(@as(u8, 12), state.config.frames);
    try std.testing.expectEqual(backend.Format.svg, backend.Format.parse("svg").?);
    try std.testing.expect(backend.Format.parse("mp4") == null);
}

test "the composer quality chip cycles with one click" {
    var state = try app_view.State.initDefault(std.testing.allocator, std.testing.io);
    defer state.deinit();
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&state, app_view.State.view), .{ .width = 1240, .height = 820 });
    defer t.deinit();
    t.settle(0.2);
    try std.testing.expect(!state.show_settings);
    try t.clickText("quality · auto");
    t.settle(0.1);
    try std.testing.expectEqual(backend.Level.low, state.config.quality);
    try std.testing.expect(!state.show_settings);
    try std.testing.expect(t.hasText("quality · low"));
}

test "the GIF decoder is reachable from the test root" {
    _ = gif;
}
