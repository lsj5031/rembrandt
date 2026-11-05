//! Submitting an immutable request and saving the completed result.
const std = @import("std");
const nanoui = @import("nanoui");
const backend = @import("backend.zig");
const log = @import("log.zig");
const State = @import("app.zig").State;
const ui = nanoui.ui;

pub fn generate(s: *State) void {
    if (s.generating or !s.hasPrompt()) return;
    const prompt = std.mem.trim(u8, s.prompt.text(), " \t\r\n");
    const refs = s.refs.items.items;
    var inputs: [16]backend.RefInput = undefined;
    for (refs, 0..) |ref, i| inputs[i] = .{ .bytes = ref.bytes, .mime = ref.mime.header() };
    const req_body = (if (refs.len > 0)
        backend.buildEditBody(s.gpa, &s.config, prompt, inputs[0..refs.len])
    else
        backend.buildBody(s.gpa, &s.config, prompt)) catch {
        s.setError("Could not build the request.");
        return;
    };
    defer s.gpa.free(req_body);
    const url = std.fmt.allocPrint(s.gpa, "{s}{s}", .{ s.config.base_url, backend.endpointFor(refs.len > 0) }) catch {
        s.setError("Could not build the request.");
        return;
    };
    defer s.gpa.free(url);

    var headers: [2]nanoui.http.Header = undefined;
    headers[0] = .{ .name = "Content-Type", .value = "application/json" };
    var hn: usize = 1;
    var auth: ?[]u8 = null;
    defer if (auth) |a| s.gpa.free(a);
    if (s.config.api_key.len > 0) {
        auth = std.fmt.allocPrint(s.gpa, "Bearer {s}", .{s.config.api_key}) catch {
            s.setError("Could not build the request.");
            return;
        };
        headers[hn] = .{ .name = "Authorization", .value = auth.? };
        hn += 1;
    }
    log.info("generate: model={s} refs={d} ({d:.1} MiB) size={s} quality={s} complexity={s} prompt_chars={d}", .{
        if (s.config.model.len == 0) "server default" else s.config.model,
        refs.len,
        @as(f64, @floatFromInt(s.refs.total)) / (1024 * 1024),
        s.config.size.api(),
        s.config.quality.api(),
        s.config.complexity.api(),
        prompt.len,
    });
    s.clearError();
    s.refs.error_len = 0;
    s.generating = true;
    s.started_at = ui.clock.now();
    s.elapsed = 0;
    if (s.window) |w| w.redraw();
    nanoui.http.fetch(s.gpa, .{
        .url = url,
        .method = "POST",
        .headers = headers[0..hn],
        .body = req_body,
        .timeout = 240,
    }, s, onGenerated);
}

fn onGenerated(s: *State, r: nanoui.http.Response) void {
    defer if (s.window) |w| w.redraw();
    s.generating = false;
    var arena = std.heap.ArenaAllocator.init(s.gpa);
    defer arena.deinit();
    if (r.status != 200) {
        const msg = if (r.body.len > 0) backend.errorMessage(arena.allocator(), r.body) else r.err;
        s.setError(if (msg.len > 0) msg else "The backend did not answer.");
        return;
    }
    const parsed = backend.parse(arena.allocator(), r.body) catch {
        s.setError("The backend sent no image.");
        return;
    };
    const image = backend.decodeInline(s.gpa, parsed.b64) catch |e| {
        s.setError(switch (e) {
            error.NotAnImage => "The backend sent an unsupported image.",
            error.TooLarge => "That image is too large to open.",
            else => "Could not decode the image.",
        });
        return;
    };
    const stamp = std.Io.Clock.real.now(s.io).toSeconds();
    const name = backend.fileName(s.gpa, stamp, image.kind) catch {
        s.gpa.free(image.bytes);
        s.setError("Out of memory.");
        return;
    };
    const path = saveImage(s, name, image.bytes) catch s.gpa.dupe(u8, name) catch {
        s.gpa.free(image.bytes);
        s.gpa.free(name);
        s.setError("Could not save the image.");
        return;
    };
    const secs = ui.clock.now() - s.started_at;
    log.info("generated: {s} {d}x{d}, {d} tokens, {d:.1}s, saved to {s}", .{ image.kind.label(), image.width, image.height, parsed.tokens, secs, path });
    s.addItem(.{
        .bytes = image.bytes,
        .name = name,
        .path = path,
        .width = image.width,
        .height = image.height,
        .tokens = parsed.tokens,
        .secs = secs,
        .kind = image.kind,
    });
    s.clearError();
}

pub fn saveImage(s: *State, name: []const u8, bytes: []const u8) ![]u8 {
    const directory = if (s.output_dir) |dir| try s.gpa.dupe(u8, dir) else blk: {
        const documents = try nanoui.path(s.gpa, .documents, "Rembrandt");
        defer s.gpa.free(documents);
        break :blk try std.fs.path.join(s.gpa, &.{ documents, "Rembrandt" });
    };
    defer s.gpa.free(directory);
    try std.Io.Dir.cwd().createDirPath(s.io, directory);
    const path = try std.fs.path.join(s.gpa, &.{ directory, name });
    errdefer s.gpa.free(path);
    try std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = path, .data = bytes });
    return path;
}
