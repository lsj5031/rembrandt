//! Owned reference images, input limits, and file-drop paths.
const std = @import("std");

pub const Limits = struct {
    max_refs: usize = 16,
    max_file_bytes: usize = 14 * 1024 * 1024,
    max_total_bytes: usize = 40 * 1024 * 1024,
};

pub const Mime = enum {
    png,
    jpeg,
    webp,

    pub fn header(m: Mime) []const u8 {
        return switch (m) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .webp => "image/webp",
        };
    }

    pub fn label(m: Mime) []const u8 {
        return switch (m) {
            .png => "PNG",
            .jpeg => "JPG",
            .webp => "WEBP",
        };
    }
};

pub const Ref = struct {
    id: u64,
    bytes: []u8,
    name: []u8,
    mime: Mime,
    width: u32 = 0,
    height: u32 = 0,

    pub fn canPreview(r: Ref) bool {
        if (r.mime != .png) return @import("builtin").os.tag == .macos;
        return r.width > 0 and r.height > 0 and r.width <= 4096 and r.height <= 4096 and
            @as(u64, r.width) * r.height <= 4 * 1024 * 1024;
    }

    fn deinit(r: Ref, gpa: std.mem.Allocator) void {
        gpa.free(r.bytes);
        gpa.free(r.name);
    }
};

pub const List = struct {
    items: std.ArrayList(Ref) = .empty,
    total: usize = 0,
    next_id: u64 = 1,
    limits: Limits = .{},
    error_text: [160]u8 = undefined,
    error_len: usize = 0,

    pub fn deinit(l: *List, gpa: std.mem.Allocator) void {
        l.clear(gpa);
        l.items.deinit(gpa);
    }

    pub fn addPath(l: *List, gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
        if (l.items.items.len >= l.limits.max_refs) return error.TooMany;
        // Zig's read limit is exclusive; a file exactly at the cap is allowed.
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(l.limits.max_file_bytes + 1)) catch |e| {
            return if (e == error.StreamTooLong) error.TooLarge else e;
        };
        defer gpa.free(bytes);
        try l.addBytes(gpa, basename(path), bytes);
    }

    pub fn addBytes(l: *List, gpa: std.mem.Allocator, name: []const u8, bytes: []const u8) !void {
        if (l.items.items.len >= l.limits.max_refs) return error.TooMany;
        if (bytes.len == 0) return error.EmptyFile;
        if (bytes.len > l.limits.max_file_bytes) return error.TooLarge;
        if (bytes.len > l.limits.max_total_bytes - l.total) return error.TotalTooLarge;
        const mime = sniff(bytes) orelse return error.NotAnImage;
        try checkEncodedSize(bytes.len, mime.header());
        const owned = try gpa.dupe(u8, bytes);
        errdefer gpa.free(owned);
        const label = try gpa.dupe(u8, basename(name));
        errdefer gpa.free(label);
        var ref: Ref = .{ .id = l.next_id, .bytes = owned, .name = label, .mime = mime };
        if (mime == .png and bytes.len >= 24 and std.mem.eql(u8, bytes[12..16], "IHDR")) {
            ref.width = std.mem.readInt(u32, bytes[16..20], .big);
            ref.height = std.mem.readInt(u32, bytes[20..24], .big);
        }
        try l.items.append(gpa, ref);
        l.next_id += 1;
        l.total += bytes.len;
        l.error_len = 0;
    }

    pub fn remove(l: *List, gpa: std.mem.Allocator, i: usize) void {
        const ref = l.items.orderedRemove(i);
        l.total -= ref.bytes.len;
        ref.deinit(gpa);
        l.error_len = 0;
    }

    pub fn clear(l: *List, gpa: std.mem.Allocator) void {
        for (l.items.items) |ref| ref.deinit(gpa);
        l.items.clearRetainingCapacity();
        l.total = 0;
        l.error_len = 0;
    }

    pub fn setError(l: *List, e: anyerror) void {
        const msg = reason(e);
        @memcpy(l.error_text[0..msg.len], msg);
        l.error_len = msg.len;
    }

    pub fn loadEnv(l: *List, gpa: std.mem.Allocator, io: std.Io, env: anytype) void {
        const raw = env.get("REMBRANDT_REFERENCES") orelse return;
        var paths = std.mem.splitScalar(u8, raw, std.fs.path.delimiter);
        var failure: ?anyerror = null;
        while (paths.next()) |path| {
            if (path.len == 0) continue;
            l.addPath(gpa, io, path) catch |e| {
                failure = e;
            };
        }
        if (failure) |e| l.setError(e);
    }
};

pub fn checkEncodedSize(bytes_len: usize, mime: []const u8) !void {
    const max_url = 20 * 1024 * 1024;
    // Check before calcSize so even a fabricated oversized slice cannot overflow.
    if (mime.len > max_url - "data:;base64,".len or bytes_len > max_url) return error.EncodedTooLarge;
    if ("data:;base64,".len + mime.len + std.base64.standard.Encoder.calcSize(bytes_len) > max_url)
        return error.EncodedTooLarge;
}

pub fn sniff(bytes: []const u8) ?Mime {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return .png;
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return .jpeg;
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return .webp;
    return null;
}

pub fn reason(e: anyerror) []const u8 {
    return switch (e) {
        error.TooMany => "Up to 16 reference images.",
        error.TooLarge => "That image is larger than 14 MiB.",
        error.EncodedTooLarge => "That image exceeds the encoded reference limit.",
        error.TotalTooLarge => "References would exceed 40 MiB in total.",
        error.NotAnImage => "References must be PNG, JPEG or WebP.",
        error.EmptyFile => "That file is empty.",
        else => "Could not read that file.",
    };
}

/// File URLs are decoded; plain paths are copied without interpreting '%' or ':'.
pub fn pathFromUrl(gpa: std.mem.Allocator, url: []const u8) !?[]u8 {
    if (!std.ascii.startsWithIgnoreCase(url, "file://")) {
        if (std.mem.indexOfScalar(u8, url, ':')) |i| {
            if (i != 1 or !std.ascii.isAlphabetic(url[0])) return null;
        }
        return try gpa.dupe(u8, url);
    }
    var raw = url[7..];
    if (std.ascii.startsWithIgnoreCase(raw, "localhost/")) raw = raw[9..];
    const unc = raw.len > 0 and raw[0] != '/';
    if (raw.len >= 3 and raw[0] == '/' and std.ascii.isAlphabetic(raw[1]) and raw[2] == ':') raw = raw[1..];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (unc) try out.appendSlice(gpa, "//");
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const ch = if (raw[i] == '%') blk: {
            if (i + 2 >= raw.len) return error.InvalidPath;
            const byte = std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch return error.InvalidPath;
            i += 2;
            break :blk byte;
        } else raw[i];
        if (ch == 0) return error.InvalidPath;
        try out.append(gpa, ch);
    }
    return try out.toOwnedSlice(gpa);
}

pub fn basename(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
    return path[i + 1 ..];
}
