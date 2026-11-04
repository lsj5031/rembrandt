//! The view and request building, driven offscreen; integration uses loopback only.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("app.zig");
const backend = @import("backend.zig");
const settings_store = @import("settings_store.zig");
const references = @import("references.zig");

test {
    _ = @import("tests_generation.zig");
}

test "the prototype's anchors are on screen" {
    var state = try app_view.State.initDefault(std.testing.allocator, std.testing.io);
    defer state.deinit();
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&state, app_view.State.view), .{ .width = 1240, .height = 820 });
    defer t.deinit();
    t.settle(0.2);
    try std.testing.expect(t.hasText("Rembrandt"));
    try std.testing.expect(t.hasText("PROMPT"));
    try std.testing.expect(t.hasText("Generate"));
    try std.testing.expect(t.hasText("RECENT"));
    try std.testing.expect(t.hasText("server default"));
    try std.testing.expect(t.hasText("127.0.0.1:3425"));
}

test "backend labels stay vendor-neutral" {
    const gpa = std.testing.allocator;
    var config = try backend.Config.defaults(gpa);
    defer config.deinit(gpa);
    try std.testing.expectEqualStrings("OpenAI-compatible", config.provider());
    try std.testing.expectEqualStrings("", config.api_key);
}

test "the size chip cycles through the three aspect ratios" {
    var state = try app_view.State.initDefault(std.testing.allocator, std.testing.io);
    defer state.deinit();
    try std.testing.expectEqual(backend.Size.landscape, state.config.size);
    state.cycleSize();
    try std.testing.expectEqual(backend.Size.square, state.config.size);
    state.cycleSize();
    try std.testing.expectEqual(backend.Size.portrait, state.config.size);
    state.cycleSize();
    try std.testing.expectEqual(backend.Size.landscape, state.config.size);
}

test "the settings sheet opens and closes" {
    var state = try app_view.State.initDefault(std.testing.allocator, std.testing.io);
    defer state.deinit();
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&state, app_view.State.view), .{ .width = 1240, .height = 820 });
    defer t.deinit();
    t.settle(0.2);
    try t.clickText("server default");
    t.settle(0.2);
    try std.testing.expect(state.show_settings);
    try std.testing.expect(t.hasText("Backend"));
    try t.clickText("Cancel");
    t.settle(0.2);
    try std.testing.expect(!state.show_settings);
}

test "Escape closes the settings sheet" {
    var state = try app_view.State.initDefault(std.testing.allocator, std.testing.io);
    defer state.deinit();
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&state, app_view.State.view), .{ .width = 1240, .height = 820 });
    defer t.deinit();
    t.settle(0.2);
    try t.clickText("server default");
    t.settle(0.2);
    try std.testing.expect(state.show_settings);
    t.key(.escape);
    t.settle(0.2);
    try std.testing.expect(!state.show_settings);
}

test "a click outside the settings sheet closes it" {
    var state = try app_view.State.initDefault(std.testing.allocator, std.testing.io);
    defer state.deinit();
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&state, app_view.State.view), .{ .width = 1240, .height = 820 });
    defer t.deinit();
    t.settle(0.2);
    try t.clickText("server default");
    t.settle(0.2);
    try std.testing.expect(state.show_settings);
    t.click(20, 300);
    t.settle(0.2);
    try std.testing.expect(!state.show_settings);
}

test "a click inside the settings sheet leaves it open" {
    var state = try app_view.State.initDefault(std.testing.allocator, std.testing.io);
    defer state.deinit();
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&state, app_view.State.view), .{ .width = 1240, .height = 820 });
    defer t.deinit();
    t.settle(0.2);
    try t.clickText("server default");
    t.settle(0.2);
    try std.testing.expect(state.show_settings);
    try t.clickText("Backend");
    t.settle(0.2);
    try std.testing.expect(state.show_settings);
}

test "the disabled Generate button does nothing" {
    var state = try app_view.State.initDefault(std.testing.allocator, std.testing.io);
    defer state.deinit();
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&state, app_view.State.view), .{ .width = 1240, .height = 820 });
    defer t.deinit();
    t.settle(0.2);
    try t.clickText("Generate");
    t.settle(0.2);
    try std.testing.expect(!state.generating);
}

test "the request is valid JSON and keeps the prompt intact" {
    const gpa = std.testing.allocator;
    var cfg = try backend.Config.defaults(gpa);
    defer cfg.deinit(gpa);
    try cfg.setModel(gpa, "mitori/gpt-image-2.5-sunburst");

    const body = try backend.buildBody(gpa, &cfg, "a \"quoted\" prompt\nwith a line break");
    defer gpa.free(body);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{});
    try std.testing.expectEqualStrings("mitori/gpt-image-2.5-sunburst", root.object.get("model").?.string);
    try std.testing.expectEqualStrings("a \"quoted\" prompt\nwith a line break", root.object.get("prompt").?.string);
    try std.testing.expectEqualStrings("1536x1024", root.object.get("size").?.string);
}

test "a bare host gets /v1; a full endpoint is normalized" {
    const gpa = std.testing.allocator;
    const a = try backend.normalize(gpa, "http://127.0.0.1:3425");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("http://127.0.0.1:3425/v1", a);

    const b = try backend.normalize(gpa, "https://relay.example.com/v1/images/generations");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("https://relay.example.com/v1", b);
    const c = try backend.normalize(gpa, "https://relay.example.com/v1/images/edits/");
    defer gpa.free(c);
    try std.testing.expectEqualStrings("https://relay.example.com/v1", c);
}

test "settings round-trip without the api key" {
    const gpa = std.testing.allocator;
    var config = try backend.Config.defaults(gpa);
    defer config.deinit(gpa);
    try config.setBase(gpa, "https://relay.example.com/v1");
    try config.setModel(gpa, "mitori/gpt-image-2.5-sunburst");
    try config.setKey(gpa, "sk-must-not-be-written");
    config.size = .portrait;

    const json = try settings_store.encode(gpa, &config);
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "sk-must-not-be-written") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "api_key") == null);

    var loaded = try backend.Config.defaults(gpa);
    defer loaded.deinit(gpa);
    try settings_store.apply(gpa, &loaded, json);
    try std.testing.expectEqualStrings("https://relay.example.com/v1", loaded.base_url);
    try std.testing.expectEqualStrings("mitori/gpt-image-2.5-sunburst", loaded.model);
    try std.testing.expectEqual(backend.Size.portrait, loaded.size);
}

pub const png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";

test "edits preserve ordered bytes, MIME, prompt and model" {
    const gpa = std.testing.allocator;
    var cfg = try backend.Config.defaults(gpa);
    defer cfg.deinit(gpa);
    const inputs = [_]backend.RefInput{
        .{ .bytes = "\x89PNG\r\n\x1a\n", .mime = "image/png" },
        .{ .bytes = "\xff\xd8\xff\x00\x01", .mime = "image/jpeg" },
        .{ .bytes = "RIFF1234WEBP", .mime = "image/webp" },
    };
    for ([_][]const u8{ "", "model\"with\\escapes" }) |model| {
        try cfg.setModel(gpa, model);
        const body = try backend.buildEditBody(gpa, &cfg, "a \"quoted\" prompt\nnext line", &inputs);
        defer gpa.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        try std.testing.expectEqualStrings("a \"quoted\" prompt\nnext line", root.get("prompt").?.string);
        try std.testing.expectEqualStrings("1536x1024", root.get("size").?.string);
        try std.testing.expectEqual(@as(i64, 1), root.get("n").?.integer);
        if (model.len == 0) try std.testing.expect(root.get("model") == null) else try std.testing.expectEqualStrings(model, root.get("model").?.string);
        const images = root.get("images").?.array.items;
        try std.testing.expectEqual(@as(usize, 3), images.len);
        for (images, inputs) |image, input| {
            const url = image.object.get("image_url").?.string;
            const prefix = try std.fmt.allocPrint(gpa, "data:{s};base64,", .{input.mime});
            defer gpa.free(prefix);
            try std.testing.expect(std.mem.startsWith(u8, url, prefix));
            const decoder = std.base64.standard.Decoder;
            const decoded = try gpa.alloc(u8, try decoder.calcSizeForSlice(url[prefix.len..]));
            defer gpa.free(decoded);
            try decoder.decode(decoded, url[prefix.len..]);
            try std.testing.expectEqualSlices(u8, input.bytes, decoded);
        }
    }
    try std.testing.expectError(error.NoReferences, backend.buildEditBody(gpa, &cfg, "p", &.{}));
    const too_many: [17]backend.RefInput = @splat(inputs[0]);
    try std.testing.expectError(error.TooMany, backend.buildEditBody(gpa, &cfg, "p", &too_many));
    try std.testing.expectEqualStrings("/images/edits", backend.endpointFor(true));
    try std.testing.expectEqualStrings("/images/generations", backend.endpointFor(false));
}

test "reference limits and ownership survive rejected additions and removal" {
    const gpa = std.testing.allocator;
    var refs: references.List = .{ .limits = .{ .max_refs = 2, .max_file_bytes = 8, .max_total_bytes = 12 } };
    defer refs.deinit(gpa);
    try std.testing.expectError(error.EmptyFile, refs.addBytes(gpa, "empty", ""));
    try std.testing.expectError(error.NotAnImage, refs.addBytes(gpa, "text.png", "text"));
    try std.testing.expectError(error.TooLarge, refs.addBytes(gpa, "big", "123456789"));
    var jpeg = [_]u8{ 255, 216, 255, 1, 2, 3, 4 };
    try refs.addBytes(gpa, "a\\test.png", &jpeg);
    jpeg[3] = 9;
    try std.testing.expectEqual(@as(u8, 1), refs.items.items[0].bytes[3]);
    try std.testing.expectEqualStrings("test.png", refs.items.items[0].name);
    try std.testing.expectEqual(references.Mime.jpeg, refs.items.items[0].mime);
    try std.testing.expectError(error.TotalTooLarge, refs.addBytes(gpa, "again", &jpeg));
    try std.testing.expectEqual(@as(usize, 7), refs.total);
    try refs.addBytes(gpa, "small", jpeg[0..3]);
    const second_id = refs.items.items[1].id;
    try std.testing.expectError(error.TooMany, refs.addBytes(gpa, "third", jpeg[0..3]));
    refs.remove(gpa, 0);
    try std.testing.expectEqual(@as(usize, 3), refs.total);
    try std.testing.expectEqual(second_id, refs.items.items[0].id);
    refs.clear(gpa);
    try std.testing.expectEqual(@as(usize, 0), refs.total);
    try refs.addBytes(gpa, "small", jpeg[0..3]);
    try std.testing.expect(refs.items.items[0].id > second_id);
    try std.testing.expectEqual(references.Mime.webp, references.sniff("RIFF1234WEBP").?);
    try std.testing.expect(references.sniff("RIFF") == null);
}

test "environment preloads keep valid files and report failures and the seventeenth image" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "valid.jpg", .data = "\xff\xd8\xff" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad.txt", .data = "text" });
    const valid = try tmp.dir.realPathFileAlloc(std.testing.io, "valid.jpg", gpa);
    defer gpa.free(valid);
    const bad = try tmp.dir.realPathFileAlloc(std.testing.io, "bad.txt", gpa);
    defer gpa.free(bad);
    const Env = struct {
        value: []const u8,
        pub fn get(env: @This(), _: []const u8) ?[]const u8 {
            return env.value;
        }
    };
    const mixed = try std.fmt.allocPrint(gpa, "{s}{c}{s}{c}{s}", .{ valid, std.fs.path.delimiter, bad, std.fs.path.delimiter, valid });
    defer gpa.free(mixed);
    var refs: references.List = .{};
    defer refs.deinit(gpa);
    refs.loadEnv(gpa, std.testing.io, Env{ .value = mixed });
    try std.testing.expectEqual(@as(usize, 2), refs.items.items.len);
    try std.testing.expectEqualStrings("References must be PNG, JPEG or WebP.", refs.error_text[0..refs.error_len]);
    for (2..16) |_| try refs.addBytes(gpa, "duplicate.jpg", "\xff\xd8\xff");
    try std.testing.expectError(error.TooMany, refs.addPath(gpa, std.testing.io, valid));
    try std.testing.expectEqual(@as(usize, 16), refs.items.items.len);
    try std.testing.expectEqual(@as(usize, 48), refs.total);
    var fresh: references.List = .{};
    defer fresh.deinit(gpa);
    fresh.loadEnv(gpa, std.testing.io, Env{ .value = "" });
    try std.testing.expectEqual(@as(usize, 0), fresh.items.items.len);
}

test "source and encoded limits accept the boundary and reject the next byte" {
    const gpa = std.testing.allocator;
    var refs: references.List = .{};
    defer refs.deinit(gpa);
    const bytes = try gpa.alloc(u8, 14 * 1024 * 1024 + 1);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..3], "\xff\xd8\xff");
    try refs.addBytes(gpa, "max.jpg", bytes[0 .. bytes.len - 1]);
    try std.testing.expectError(error.TooLarge, refs.addBytes(gpa, "too-big.jpg", bytes));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "max.jpg", .data = bytes[0 .. bytes.len - 1] });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "max.jpg", gpa);
    defer gpa.free(path);
    try refs.addPath(gpa, std.testing.io, path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "max.jpg", .data = bytes });
    try std.testing.expectError(error.TooLarge, refs.addPath(gpa, std.testing.io, path));
    var cfg = try backend.Config.defaults(gpa);
    defer cfg.deinit(gpa);
    // Independently derived: PNG/WebP prefixes are 22/23 chars, JPEG is 23.
    for ([_][]const u8{ "image/png", "image/jpeg", "image/webp" }) |mime| {
        const prefix_len: usize = if (std.mem.eql(u8, mime, "image/png")) 22 else 23;
        const max_bytes = ((20_971_520 - prefix_len) / 4) * 3;
        try references.checkEncodedSize(max_bytes, mime);
        try std.testing.expectError(error.EncodedTooLarge, references.checkEncodedSize(max_bytes + 1, mime));
        const oversized = try gpa.alloc(u8, max_bytes + 1);
        defer gpa.free(oversized);
        try std.testing.expectError(error.EncodedTooLarge, backend.buildEditBody(gpa, &cfg, "p", &.{.{ .bytes = oversized, .mime = mime }}));
    }
    try std.testing.expectEqual(@as(usize, 2), refs.items.items.len);
}

test "file URLs preserve platform paths and reject malformed escapes" {
    const gpa = std.testing.allocator;
    const cases = .{
        .{ "file:///C:/x/a%20b.png", "C:/x/a b.png" },
        .{ "file://server/share/x.png", "//server/share/x.png" },
        .{ "file:///tmp/a%20b.png", "/tmp/a b.png" },
        .{ "file://localhost/tmp/a.png", "/tmp/a.png" },
        .{ "C:\\pictures\\a%20b.png", "C:\\pictures\\a%20b.png" },
    };
    inline for (cases) |pair| {
        const path = (try references.pathFromUrl(gpa, pair[0])).?;
        defer gpa.free(path);
        try std.testing.expectEqualStrings(pair[1], path);
    }
    try std.testing.expect(try references.pathFromUrl(gpa, "https://example.com/a.png") == null);
    try std.testing.expectError(error.InvalidPath, references.pathFromUrl(gpa, "file:///tmp/%ZZ.png"));
    try std.testing.expectError(error.InvalidPath, references.pathFromUrl(gpa, "file:///tmp/%00.png"));
}

test "reference strip handles drops, remove, clear, and reuse during generation" {
    const gpa = std.testing.allocator;
    var state = try app_view.State.initDefault(gpa, std.testing.io);
    defer state.deinit();
    const image = try backend.decodePng(gpa, png_b64);
    defer gpa.free(image.bytes);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ref.png", .data = image.bytes });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "ref.png", gpa);
    defer gpa.free(path);
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, app_view.State.view), .{ .width = 1240, .height = 820 });
    defer t.deinit();
    t.drop(100, 150, &.{path}, "");
    t.drop(100, 150, &.{path}, "");
    try std.testing.expectEqual(@as(usize, 2), state.refs.items.items.len);
    try t.clickText("Generate"); // References do not replace the prompt.
    try std.testing.expect(!state.generating);
    state.generating = true;
    t.frame();
    try std.testing.expect(t.hasText("Reference changes apply to the next generation."));
    // Use the control's accessibility rect, independent of composer geometry.
    var remove_rect: ?ui.Rect = null;
    for (t.ctx.a11y_items.items) |item| {
        if (std.mem.eql(u8, item.label, "Remove reference")) {
            remove_rect = t.ctx.rects.get(item.id);
            break;
        }
    }
    const r = remove_rect orelse return error.MissingRemove;
    t.click(r.x + r.w / 2, r.y + r.h / 2);
    t.frame();
    try std.testing.expectEqual(@as(usize, 1), state.refs.items.items.len);
    try t.clickText("Clear");
    t.frame();
    try std.testing.expectEqual(@as(usize, 0), state.refs.items.items.len);
    t.drop(100, 150, &.{path}, "");
    try std.testing.expectEqual(@as(usize, 1), state.refs.items.items.len);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ref.png", .data = "bad" });
    t.drop(100, 150, &.{path}, "");
    try std.testing.expectEqual(@as(usize, 1), state.refs.items.items.len);
    try std.testing.expect(state.refs.error_len > 0);
    state.addItem(.{ .bytes = try gpa.dupe(u8, image.bytes), .name = try gpa.dupe(u8, "result.png"), .path = try gpa.dupe(u8, path), .width = 1, .height = 1, .tokens = 0, .secs = 0 });
    t.frame();
    try t.clickText("Use as reference");
    try std.testing.expectEqual(@as(usize, 2), state.refs.items.items.len);
    try std.testing.expect(state.refs.items.items[1].bytes.ptr != state.history[0].bytes.ptr);
    try std.testing.expectEqual(@as(usize, 0), state.refs.error_len);
}

test "PNG thumbnail guard retains large references without decoding them" {
    const gpa = std.testing.allocator;
    var refs: references.List = .{};
    defer refs.deinit(gpa);
    var bytes: [24]u8 = @splat(0);
    @memcpy(bytes[0..8], "\x89PNG\r\n\x1a\n");
    @memcpy(bytes[12..16], "IHDR");
    std.mem.writeInt(u32, bytes[16..20], 2048, .big);
    std.mem.writeInt(u32, bytes[20..24], 2048, .big);
    try refs.addBytes(gpa, "at-limit.png", &bytes);
    try std.testing.expect(refs.items.items[0].canPreview());
    std.mem.writeInt(u32, bytes[16..20], 2049, .big);
    try refs.addBytes(gpa, "large.png", &bytes);
    try std.testing.expect(!refs.items.items[1].canPreview());
    std.mem.writeInt(u32, bytes[16..20], 4097, .big);
    std.mem.writeInt(u32, bytes[20..24], 1, .big);
    try refs.addBytes(gpa, "wide.png", &bytes);
    try std.testing.expect(!refs.items.items[2].canPreview());
}
