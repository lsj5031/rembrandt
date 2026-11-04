//! The view and the request building, driven offscreen: no window, no network.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("app.zig");
const backend = @import("backend.zig");
const settings_store = @import("settings_store.zig");

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
