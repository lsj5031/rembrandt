//! The OpenAI-compatible image backend Rembrandt talks to. It answers
//! generations or reference-image edits with a b64_json image: PNG, GIF or SVG.
const std = @import("std");
const references = @import("references.zig");

const default_base = "http://127.0.0.1:3425/v1";
const default_key = "";

pub const Size = enum {
    landscape,
    square,
    portrait,

    pub fn api(self: Size) []const u8 {
        return switch (self) {
            .landscape => "1536x1024",
            .square => "1024x1024",
            .portrait => "1024x1536",
        };
    }

    pub fn label(self: Size) []const u8 {
        return switch (self) {
            .landscape => "1536 × 1024",
            .square => "1024 × 1024",
            .portrait => "1024 × 1536",
        };
    }

    pub fn cycle(self: Size) Size {
        return switch (self) {
            .landscape => .square,
            .square => .portrait,
            .portrait => .landscape,
        };
    }

    pub fn parse(s: []const u8) ?Size {
        if (std.mem.eql(u8, s, "1536x1024")) return .landscape;
        if (std.mem.eql(u8, s, "1024x1024")) return .square;
        if (std.mem.eql(u8, s, "1024x1536")) return .portrait;
        return null;
    }
};

/// A per-request Images 2.6 control. `auto` is the server's own default and
/// is left out of the body, so a backend that predates the field sees the
/// same request it always did.
pub const Level = enum {
    auto,
    low,
    medium,
    high,

    pub fn api(self: Level) []const u8 {
        return switch (self) {
            .auto => "auto",
            .low => "low",
            .medium => "medium",
            .high => "high",
        };
    }

    pub fn cycle(self: Level) Level {
        return switch (self) {
            .auto => .low,
            .low => .medium,
            .medium => .high,
            .high => .auto,
        };
    }

    pub fn parse(s: []const u8) ?Level {
        if (std.mem.eql(u8, s, "auto")) return .auto;
        if (std.mem.eql(u8, s, "low")) return .low;
        if (std.mem.eql(u8, s, "medium")) return .medium;
        if (std.mem.eql(u8, s, "high")) return .high;
        return null;
    }
};

/// The response formats the API can return: PNG by default, an animated
/// GIF, or an SVG document.
pub const Format = enum {
    png,
    gif,
    svg,

    pub fn api(self: Format) []const u8 {
        return switch (self) {
            .png => "png",
            .gif => "gif",
            .svg => "svg",
        };
    }

    pub fn label(self: Format) []const u8 {
        return switch (self) {
            .png => "PNG",
            .gif => "GIF",
            .svg => "SVG",
        };
    }

    pub fn cycle(self: Format) Format {
        return switch (self) {
            .png => .gif,
            .gif => .svg,
            .svg => .png,
        };
    }

    pub fn parse(s: []const u8) ?Format {
        if (std.ascii.eqlIgnoreCase(s, "png")) return .png;
        if (std.ascii.eqlIgnoreCase(s, "gif")) return .gif;
        if (std.ascii.eqlIgnoreCase(s, "svg")) return .svg;
        return null;
    }
};

/// The frames chip's presets; the API accepts 2 through 16.
pub fn nextFrames(n: u8) u8 {
    for ([_]u8{ 4, 6, 9, 12, 16 }) |candidate| {
        if (candidate > n) return candidate;
    }
    return 4;
}

pub fn nextFrameMs(ms: u16) u16 {
    for ([_]u16{ 100, 150, 200, 300, 500 }) |candidate| {
        if (candidate > ms) return candidate;
    }
    return 100;
}

fn parseFrames(raw: []const u8) ?u8 {
    const n = std.fmt.parseInt(u8, raw, 10) catch return null;
    return if (n >= 2 and n <= 16) n else null;
}

fn parseFrameMs(raw: []const u8) ?u16 {
    const n = std.fmt.parseInt(u16, raw, 10) catch return null;
    return if (n >= 20 and n <= 60_000) n else null;
}

/// The Backend sheet's per-request knobs. The view edits these in a draft
/// and copies them into `Config` only when Save is pressed.
pub const RequestOptions = struct {
    quality: Level = .auto,
    complexity: Level = .auto,
    format: Format = .png,
    frames: u8 = 9,
    frame_ms: u16 = 200,
};

pub const Config = struct {
    base_url: []u8,
    api_key: []u8,
    model: []u8,
    size: Size = .landscape,
    quality: Level = .auto,
    complexity: Level = .auto,
    format: Format = .png,
    frames: u8 = 9,
    frame_ms: u16 = 200,
    n: u8 = 1,

    pub fn init(gpa: std.mem.Allocator, env: anytype) !Config {
        const base = try normalize(gpa, env.get("REMBRANDT_BASE_URL") orelse default_base);
        errdefer gpa.free(base);
        const key = try gpa.dupe(u8, std.mem.trim(u8, env.get("REMBRANDT_API_KEY") orelse default_key, " \t\r\n"));
        errdefer gpa.free(key);
        const model = try gpa.dupe(u8, std.mem.trim(u8, env.get("REMBRANDT_MODEL") orelse "", " \t\r\n"));
        errdefer gpa.free(model);
        return .{
            .base_url = base,
            .api_key = key,
            .model = model,
            .size = Size.parse(env.get("REMBRANDT_SIZE") orelse "") orelse .landscape,
            .quality = Level.parse(env.get("REMBRANDT_QUALITY") orelse "") orelse .auto,
            .complexity = Level.parse(env.get("REMBRANDT_COMPLEXITY") orelse "") orelse .auto,
            .format = Format.parse(env.get("REMBRANDT_FORMAT") orelse "") orelse .png,
            .frames = parseFrames(env.get("REMBRANDT_FRAMES") orelse "") orelse 9,
            .frame_ms = parseFrameMs(env.get("REMBRANDT_FRAME_MS") orelse "") orelse 200,
        };
    }

    pub fn defaults(gpa: std.mem.Allocator) !Config {
        return .{
            .base_url = try normalize(gpa, default_base),
            .api_key = try gpa.dupe(u8, default_key),
            .model = try gpa.dupe(u8, ""),
        };
    }

    pub fn deinit(c: *Config, gpa: std.mem.Allocator) void {
        gpa.free(c.base_url);
        gpa.free(c.api_key);
        gpa.free(c.model);
        c.* = undefined;
    }

    pub fn setBase(c: *Config, gpa: std.mem.Allocator, raw: []const u8) !void {
        const next = try normalize(gpa, raw);
        gpa.free(c.base_url);
        c.base_url = next;
    }

    pub fn setKey(c: *Config, gpa: std.mem.Allocator, raw: []const u8) !void {
        const next = try gpa.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
        gpa.free(c.api_key);
        c.api_key = next;
    }

    pub fn setModel(c: *Config, gpa: std.mem.Allocator, raw: []const u8) !void {
        const next = try gpa.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
        gpa.free(c.model);
        c.model = next;
    }

    pub fn isLocal(c: *const Config) bool {
        return std.mem.indexOf(u8, c.base_url, "127.0.0.1") != null or
            std.mem.indexOf(u8, c.base_url, "localhost") != null or
            std.mem.indexOf(u8, c.base_url, "0.0.0.0") != null;
    }

    pub fn provider(_: *const Config) []const u8 {
        return "OpenAI-compatible";
    }

    /// The endpoint as the prototype shows it: no scheme, no /v1.
    pub fn endpoint(c: *const Config) []const u8 {
        var u = c.base_url;
        if (std.mem.startsWith(u8, u, "https://")) u = u[8..] else if (std.mem.startsWith(u8, u, "http://")) u = u[7..];
        if (std.mem.endsWith(u8, u, "/v1")) u = u[0 .. u.len - 3];
        return u;
    }

    /// The chip's label: the model's last segment, or the server's default.
    pub fn modelShort(c: *const Config, buf: []u8) []const u8 {
        if (c.model.len == 0) return "server default";
        const base = if (std.mem.lastIndexOfScalar(u8, c.model, '/')) |i| c.model[i + 1 ..] else c.model;
        if (base.len <= 26) return base;
        return std.fmt.bufPrint(buf, "{s}…", .{base[0..25]}) catch base[0..26];
    }
};

pub const Item = struct {
    bytes: []u8,
    name: []u8,
    path: []u8,
    width: u32,
    height: u32,
    tokens: u64,
    secs: f64,
    kind: Format = .png,
    demo: bool = false,
};

pub const Image = struct {
    bytes: []u8,
    width: u32,
    height: u32,
    kind: Format = .png,
};

pub const PixelSize = struct { width: u32, height: u32 };

pub const Parsed = struct {
    b64: []const u8,
    tokens: u64,
};

/// "http://127.0.0.1:3425" and ".../v1" both become ".../v1"; a full
/// endpoint pasted in loses its /images/generations or /images/edits.
pub fn normalize(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0) s = default_base;
    while (s.len > 0 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    inline for (.{ "/images/generations", "/images/edits" }) |suffix| {
        if (std.mem.endsWith(u8, s, suffix)) s = s[0 .. s.len - suffix.len];
    }
    if (std.mem.endsWith(u8, s, "/v1")) return gpa.dupe(u8, s);
    return std.fmt.allocPrint(gpa, "{s}/v1", .{s});
}

pub fn buildBody(gpa: std.mem.Allocator, cfg: *const Config, prompt: []const u8) ![]u8 {
    const p = try escapeJson(gpa, prompt);
    defer gpa.free(p);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '{');
    if (cfg.model.len > 0) {
        const m = try escapeJson(gpa, cfg.model);
        defer gpa.free(m);
        try out.appendSlice(gpa, "\"model\":\"");
        try out.appendSlice(gpa, m);
        try out.appendSlice(gpa, "\",");
    }
    try out.appendSlice(gpa, "\"prompt\":\"");
    try out.appendSlice(gpa, p);
    var n_buf: [8]u8 = undefined;
    const n_text = try std.fmt.bufPrint(&n_buf, "{d}", .{cfg.n});
    try out.appendSlice(gpa, "\",\"n\":");
    try out.appendSlice(gpa, n_text);
    try out.appendSlice(gpa, ",\"size\":\"");
    try out.appendSlice(gpa, cfg.size.api());
    try out.append(gpa, '"');
    try appendLevel(&out, gpa, "quality", cfg.quality);
    try appendLevel(&out, gpa, "complexity", cfg.complexity);
    switch (cfg.format) {
        .png => {},
        .svg => try out.appendSlice(gpa, ",\"output_format\":\"svg\""),
        .gif => {
            var tail_buf: [96]u8 = undefined;
            const tail = try std.fmt.bufPrint(&tail_buf, ",\"output_format\":\"gif\",\"frame_count\":{d},\"frame_duration_ms\":{d}", .{ cfg.frames, cfg.frame_ms });
            try out.appendSlice(gpa, tail);
        },
    }
    try out.append(gpa, '}');
    return out.toOwnedSlice(gpa);
}

fn appendLevel(out: *std.ArrayList(u8), gpa: std.mem.Allocator, name: []const u8, level: Level) !void {
    if (level == .auto) return;
    try out.appendSlice(gpa, ",\"");
    try out.appendSlice(gpa, name);
    try out.appendSlice(gpa, "\":\"");
    try out.appendSlice(gpa, level.api());
    try out.append(gpa, '"');
}

pub const RefInput = struct { bytes: []const u8, mime: []const u8 };

pub fn endpointFor(has_refs: bool) []const u8 {
    return if (has_refs) "/images/edits" else "/images/generations";
}

pub fn buildEditBody(gpa: std.mem.Allocator, cfg: *const Config, prompt: []const u8, refs: []const RefInput) ![]u8 {
    if (refs.len == 0) return error.NoReferences;
    if (refs.len > 16) return error.TooMany;
    var capacity: usize = 0;
    for (refs) |ref| {
        try references.checkEncodedSize(ref.bytes.len, ref.mime);
        capacity += std.base64.standard.Encoder.calcSize(ref.bytes.len) + ref.mime.len + 40;
    }
    const base = try buildBody(gpa, cfg, prompt);
    defer gpa.free(base);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacityPrecise(gpa, base.len + capacity + 16);
    try out.appendSlice(gpa, base[0 .. base.len - 1]);
    try out.appendSlice(gpa, ",\"images\":[");
    for (refs, 0..) |ref, i| {
        if (i > 0) try out.append(gpa, ',');
        try out.appendSlice(gpa, "{\"image_url\":\"data:");
        try out.appendSlice(gpa, ref.mime);
        try out.appendSlice(gpa, ";base64,");
        const dst = try out.addManyAsSlice(gpa, std.base64.standard.Encoder.calcSize(ref.bytes.len));
        _ = std.base64.standard.Encoder.encode(dst, ref.bytes);
        try out.appendSlice(gpa, "\"}");
    }
    try out.appendSlice(gpa, "]}");
    return out.toOwnedSlice(gpa);
}

pub fn escapeJson(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        else => {
            if (ch < 0x20) {
                var buf: [6]u8 = undefined;
                const esc = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch}) catch unreachable;
                try out.appendSlice(gpa, esc);
            } else try out.append(gpa, ch);
        },
    };
    return out.toOwnedSlice(gpa);
}

pub fn parse(arena: std.mem.Allocator, body: []const u8) !Parsed {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    const data = root.object.get("data") orelse return error.NoData;
    const items = data.array.items;
    if (items.len == 0) return error.NoData;
    const image = items[0].object.get("b64_json") orelse return error.NoImage;
    var tokens: u64 = 0;
    if (root.object.get("usage")) |usage| switch (usage) {
        .object => |obj| if (obj.get("total_tokens")) |t| switch (t) {
            .integer => |n| tokens = @intCast(@max(0, n)),
            else => {},
        },
        else => {},
    };
    return .{ .b64 = image.string, .tokens = tokens };
}

pub fn decodePng(gpa: std.mem.Allocator, b64: []const u8) !Image {
    const decoder = std.base64.standard.Decoder;
    const n = decoder.calcSizeForSlice(b64) catch return error.BadBase64;
    const bytes = try gpa.alloc(u8, n);
    errdefer gpa.free(bytes);
    decoder.decode(bytes, b64) catch return error.BadBase64;
    if (bytes.len < 24 or !std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return error.NotPng;
    const w = std.mem.readInt(u32, bytes[16..20], .big);
    const h = std.mem.readInt(u32, bytes[20..24], .big);
    return .{ .bytes = bytes, .width = w, .height = h };
}

pub fn pngSize(bytes: []const u8) ?PixelSize {
    if (bytes.len < 24 or !std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return null;
    return .{
        .width = std.mem.readInt(u32, bytes[16..20], .big),
        .height = std.mem.readInt(u32, bytes[20..24], .big),
    };
}

pub fn gifSize(bytes: []const u8) ?PixelSize {
    if (bytes.len < 10) return null;
    if (!std.mem.eql(u8, bytes[0..6], "GIF87a") and !std.mem.eql(u8, bytes[0..6], "GIF89a")) return null;
    return .{
        .width = std.mem.readInt(u16, bytes[6..8], .little),
        .height = std.mem.readInt(u16, bytes[8..10], .little),
    };
}

/// The width and height in an SVG's opening tag, else its viewBox.
pub fn svgSize(bytes: []const u8) ?PixelSize {
    const start = std.mem.indexOf(u8, bytes[0..@min(bytes.len, 4096)], "<svg") orelse return null;
    const close = std.mem.indexOfScalar(u8, bytes[start..], '>') orelse return null;
    const tag = bytes[start .. start + close];
    if (attrNumber(tag, "width")) |w| {
        if (attrNumber(tag, "height")) |h| return .{ .width = pixelCount(w), .height = pixelCount(h) };
    }
    if (attrValue(tag, "viewBox")) |view| {
        var parts = std.mem.tokenizeAny(u8, view, " ,\t\r\n");
        _ = parts.next() orelse return null;
        _ = parts.next() orelse return null;
        const w = std.fmt.parseFloat(f32, parts.next() orelse return null) catch return null;
        const h = std.fmt.parseFloat(f32, parts.next() orelse return null) catch return null;
        if (w <= 0 or h <= 0) return null;
        return .{ .width = pixelCount(w), .height = pixelCount(h) };
    }
    return null;
}

fn attrValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (at < tag.len) {
        const rel = std.mem.indexOf(u8, tag[at..], name) orelse return null;
        const i = at + rel;
        at = i + name.len;
        if (i > 0) {
            const before = tag[i - 1];
            if (std.ascii.isAlphanumeric(before) or before == '-' or before == ':' or before == '_') continue;
        }
        var j = i + name.len;
        while (j < tag.len and (tag[j] == ' ' or tag[j] == '\t')) j += 1;
        if (j >= tag.len or tag[j] != '=') continue;
        j += 1;
        while (j < tag.len and (tag[j] == ' ' or tag[j] == '\t')) j += 1;
        if (j >= tag.len or (tag[j] != '"' and tag[j] != '\'')) continue;
        const quote = tag[j];
        const close = std.mem.indexOfScalar(u8, tag[j + 1 ..], quote) orelse return null;
        return tag[j + 1 .. j + 1 + close];
    }
    return null;
}

fn attrNumber(tag: []const u8, name: []const u8) ?f32 {
    const raw = attrValue(tag, name) orelse return null;
    var end: usize = 0;
    while (end < raw.len) : (end += 1) {
        const ch = raw[end];
        if (!(std.ascii.isDigit(ch) or ch == '.' or ch == '-' or ch == '+' or ch == 'e' or ch == 'E')) break;
    }
    if (end == 0) return null;
    const value = std.fmt.parseFloat(f32, raw[0..end]) catch return null;
    return if (value > 0) value else null;
}

fn pixelCount(value: f32) u32 {
    return @intFromFloat(@min(@round(value), 100_000));
}

/// What the backend actually returned: the request's format is a hint, not
/// a guarantee.
pub fn sniffFormat(bytes: []const u8) ?Format {
    if (bytes.len >= 8 and std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return .png;
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) return .gif;
    if (std.mem.indexOf(u8, bytes[0..@min(bytes.len, 4096)], "<svg") != null) return .svg;
    return null;
}

pub fn formatSize(format: Format, bytes: []const u8) ?PixelSize {
    return switch (format) {
        .png => pngSize(bytes),
        .gif => gifSize(bytes),
        .svg => svgSize(bytes),
    };
}

pub fn decodeInline(gpa: std.mem.Allocator, b64: []const u8) !Image {
    const decoder = std.base64.standard.Decoder;
    const n = decoder.calcSizeForSlice(b64) catch return error.BadBase64;
    if (n > 64 << 20) return error.TooLarge;
    const bytes = try gpa.alloc(u8, n);
    errdefer gpa.free(bytes);
    decoder.decode(bytes, b64) catch return error.BadBase64;
    const kind = sniffFormat(bytes) orelse return error.NotAnImage;
    const dims = formatSize(kind, bytes);
    return .{
        .bytes = bytes,
        .width = if (dims) |d| d.width else 0,
        .height = if (dims) |d| d.height else 0,
        .kind = kind,
    };
}

pub fn fileName(gpa: std.mem.Allocator, stamp: anytype, kind: Format) ![]u8 {
    return std.fmt.allocPrint(gpa, "rembrandt-{d}.{s}", .{ stamp, kind.api() });
}

pub fn errorMessage(arena: std.mem.Allocator, body: []const u8) []const u8 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return shorten(body);
    const err = root.object.get("error") orelse return shorten(body);
    switch (err) {
        .object => |obj| if (obj.get("message")) |m| switch (m) {
            .string => |s| return s,
            else => {},
        },
        else => {},
    }
    return shorten(body);
}

fn shorten(body: []const u8) []const u8 {
    return body[0..@min(body.len, 300)];
}
