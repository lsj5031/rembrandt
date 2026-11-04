//! The OpenAI-compatible image backend Rembrandt talks to. It answers
//! POST /v1/images/generations with a b64_json PNG; that response is all this
//! needs to know about the service behind it.
const std = @import("std");

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

pub const Config = struct {
    base_url: []u8,
    api_key: []u8,
    model: []u8,
    size: Size = .landscape,
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
    demo: bool = false,
};

pub const Image = struct {
    bytes: []u8,
    width: u32,
    height: u32,
};

pub const PixelSize = struct { width: u32, height: u32 };

pub const Parsed = struct {
    b64: []const u8,
    tokens: u64,
};

/// "http://127.0.0.1:3425" and ".../v1" both become ".../v1"; a full
/// endpoint pasted in loses its /images/generations.
pub fn normalize(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0) s = default_base;
    if (std.mem.endsWith(u8, s, "/images/generations")) s = s[0 .. s.len - "/images/generations".len];
    while (s.len > 0 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    if (std.mem.endsWith(u8, s, "/v1")) return gpa.dupe(u8, s);
    return std.fmt.allocPrint(gpa, "{s}/v1", .{s});
}

pub fn buildBody(gpa: std.mem.Allocator, cfg: *const Config, prompt: []const u8) ![]u8 {
    const p = try escapeJson(gpa, prompt);
    defer gpa.free(p);
    if (cfg.model.len == 0) {
        return std.fmt.allocPrint(gpa, "{{\"prompt\":\"{s}\",\"n\":{d},\"size\":\"{s}\"}}", .{ p, cfg.n, cfg.size.api() });
    }
    const m = try escapeJson(gpa, cfg.model);
    defer gpa.free(m);
    return std.fmt.allocPrint(gpa, "{{\"model\":\"{s}\",\"prompt\":\"{s}\",\"n\":{d},\"size\":\"{s}\"}}", .{ m, p, cfg.n, cfg.size.api() });
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
