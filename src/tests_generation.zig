//! Exercise the real Generate path against a disposable loopback HTTP server.
const std = @import("std");
const ui = @import("nanoui").ui;
const State = @import("app.zig").State;
const backend = @import("backend.zig");
const png_b64 = @import("tests.zig").png_b64;
const gpa = std.testing.allocator;
const io = std.testing.io;

const Stub = struct {
    server: std.Io.net.Server,
    captured: std.atomic.Value(usize) = .init(0),
    released: std.atomic.Value(usize) = .init(0),
    accepted: std.atomic.Value(usize) = .init(0),
    heads: [5]?[]u8 = @splat(null),
    bodies: [5]?[]u8 = @splat(null),

    fn serve(s: *Stub) !void {
        var i: usize = 0;
        while (true) : (i += 1) {
            const stream = try s.server.accept(io);
            defer stream.close(io);
            s.accepted.store(i + 1, .release);
            if (i >= s.bodies.len) return error.UnexpectedRetry;
            var read_buffer: [8192]u8 = undefined;
            var write_buffer: [4096]u8 = undefined;
            var reader = stream.reader(io, &read_buffer);
            var writer = stream.writer(io, &write_buffer);
            var http = std.http.Server.init(&reader.interface, &writer.interface);
            var request = try http.receiveHead();
            s.heads[i] = try gpa.dupe(u8, request.head_buffer);
            const body_reader = try request.readerExpectContinue(&.{});
            s.bodies[i] = try body_reader.allocRemaining(gpa, .limited(1 << 20));
            s.captured.store(i + 1, .release);
            while (s.released.load(.acquire) <= i) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
            try request.respond(if (i == 4) "{\"error\":{\"message\":\"edits rejected\"}}" else "{\"data\":[{\"b64_json\":\"" ++ png_b64 ++ "\"}]}", .{
                .status = if (i == 4) .unprocessable_entity else .ok,
                .keep_alive = false,
            });
        }
    }

    fn deinit(s: *Stub) void {
        s.server.deinit(io);
        for (s.heads, s.bodies) |head, body| {
            if (head) |bytes| gpa.free(bytes);
            if (body) |bytes| gpa.free(bytes);
        }
    }
};

fn waitFor(t: *ui.Tester, s: *Stub, state: *State, count: usize, completed: bool) !void {
    const end = ui.clock.now() + 5;
    while (s.captured.load(.acquire) < count or (completed and state.generating)) {
        if (ui.clock.now() > end) return error.RequestTimedOut;
        try t.runScript("live:0.01");
    }
}

test "Generate routes zero, one and sixteen references and snapshots in-flight bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(directory);
    var state = try State.initDefault(gpa, io);
    defer state.deinit();
    state.output_dir = directory;
    state.prompt.set("a \"quoted\" edit\nwith a second line");
    try state.config.setModel(gpa, "test-model");
    try state.config.setKey(gpa, "test-key");
    var stub: Stub = .{ .server = try (try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0)).listen(io, .{}) };
    defer stub.deinit();
    var serving = try std.Io.concurrent(io, Stub.serve, .{&stub});
    defer _ = serving.cancel(io) catch {};
    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v1", .{stub.server.socket.address.getPort()});
    defer gpa.free(base);
    try state.config.setBase(gpa, base);
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, State.view), .{ .width = 1240, .height = 820, .scale = 1 });
    defer t.deinit();
    // Never let a failure tear down State while an HTTP callback can still use it.
    defer {
        stub.released.store(99, .release);
        var attempts: usize = 0;
        while (state.generating and attempts < 100) : (attempts += 1) t.runScript("live:0.05") catch {};
    }
    const image = try backend.decodePng(gpa, png_b64);
    defer gpa.free(image.bytes);
    for ([_]usize{ 0, 1, 1, 16, 1 }, 0..) |count, i| {
        if (i != 2) {
            state.refs.clear(gpa);
            for (0..count) |j| {
                // Distinct, sniffable bytes test ordering; only the response must decode.
                const bytes = [_]u8{ 255, 216, 255, @intCast(j) };
                try state.refs.addBytes(gpa, "ref.jpg", &bytes);
            }
        }
        t.frame();
        try t.clickText("Generate");
        try std.testing.expect(state.generating);
        // Mutate while the server withholds its answer; the next call uses the replacement.
        if (i == 1) {
            try t.clickText("Clear");
            t.frame();
            try state.refs.addBytes(gpa, "replacement.png", image.bytes);
        }
        try waitFor(&t, &stub, &state, i + 1, false);
        const head = stub.heads[i].?;
        try std.testing.expect(std.mem.startsWith(u8, head, if (count == 0) "POST /v1/images/generations " else "POST /v1/images/edits "));
        try std.testing.expect(std.ascii.findIgnoreCase(head, "content-type: application/json") != null);
        try std.testing.expect(std.ascii.findIgnoreCase(head, "authorization: Bearer test-key") != null);
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, stub.bodies[i].?, .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        try std.testing.expectEqualStrings(state.prompt.text(), root.get("prompt").?.string);
        try std.testing.expectEqualStrings("test-model", root.get("model").?.string);
        try std.testing.expectEqualStrings("1536x1024", root.get("size").?.string);
        try std.testing.expectEqual(@as(i64, 1), root.get("n").?.integer);
        if (count == 0) {
            const expected = try backend.buildBody(gpa, &state.config, state.prompt.text());
            defer gpa.free(expected);
            try std.testing.expectEqualStrings(expected, stub.bodies[i].?);
        } else {
            const images = root.get("images").?.array.items;
            try std.testing.expectEqual(count, images.len);
            for (images, 0..) |ref, j| {
                const url = ref.object.get("image_url").?.string;
                if (i == 2) {
                    try std.testing.expectEqualStrings("data:image/png;base64," ++ png_b64, url);
                } else {
                    try std.testing.expect(std.mem.startsWith(u8, url, "data:image/jpeg;base64,"));
                    var decoded: [4]u8 = undefined;
                    try std.base64.standard.Decoder.decode(&decoded, url["data:image/jpeg;base64,".len..]);
                    try std.testing.expectEqualSlices(u8, &.{ 255, 216, 255, @as(u8, @intCast(j)) }, &decoded);
                }
            }
        }
        stub.released.store(i + 1, .release);
        try waitFor(&t, &stub, &state, i + 1, true);
        if (i < 4) {
            try std.testing.expectEqual(@as(usize, 0), state.error_len);
            const saved = try std.Io.Dir.cwd().readFileAlloc(io, state.history[0].path, gpa, .limited(1024));
            defer gpa.free(saved);
            try std.testing.expectEqualSlices(u8, image.bytes, saved);
        } else {
            try std.testing.expectEqualStrings("edits rejected", state.error_text[0..state.error_len]);
            try t.runScript("live:0.1");
            try std.testing.expectEqual(@as(usize, 5), stub.accepted.load(.acquire));
        }
    }
}
