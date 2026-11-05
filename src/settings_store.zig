//! The persisted half of Backend settings: base URL, model, size, quality,
//! complexity and the output format. The API key is deliberately absent — it
//! stays in memory only.
const std = @import("std");
const nanoui = @import("nanoui");
const backend = @import("backend.zig");

pub fn path(gpa: std.mem.Allocator) ![]u8 {
    const directory = try nanoui.path(gpa, .data, "Rembrandt");
    defer gpa.free(directory);
    return std.fs.path.join(gpa, &.{ directory, "settings.json" });
}

pub fn load(gpa: std.mem.Allocator, io: std.Io, file_path: []const u8, config: *backend.Config) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .limited(256 * 1024));
    defer gpa.free(bytes);
    try apply(gpa, config, bytes);
}

pub fn save(gpa: std.mem.Allocator, io: std.Io, file_path: []const u8, config: *const backend.Config) !void {
    const body = try encode(gpa, config);
    defer gpa.free(body);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = body });
}

pub fn encode(gpa: std.mem.Allocator, config: *const backend.Config) ![]u8 {
    const base = try backend.escapeJson(gpa, config.base_url);
    defer gpa.free(base);
    const model = try backend.escapeJson(gpa, config.model);
    defer gpa.free(model);
    return std.fmt.allocPrint(gpa, "{{\"base_url\":\"{s}\",\"model\":\"{s}\",\"size\":\"{s}\",\"quality\":\"{s}\",\"complexity\":\"{s}\",\"format\":\"{s}\",\"frames\":{d},\"frame_ms\":{d}}}", .{ base, model, config.size.api(), config.quality.api(), config.complexity.api(), config.format.api(), config.frames, config.frame_ms });
}

pub fn apply(gpa: std.mem.Allocator, config: *backend.Config, bytes: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), bytes, .{});
    switch (root) {
        .object => |obj| {
            if (obj.get("base_url")) |v| switch (v) {
                .string => |str| config.setBase(gpa, str) catch {},
                else => {},
            };
            if (obj.get("model")) |v| switch (v) {
                .string => |str| config.setModel(gpa, str) catch {},
                else => {},
            };
            if (obj.get("size")) |v| switch (v) {
                .string => |str| {
                    if (backend.Size.parse(str)) |size| config.size = size;
                },
                else => {},
            };
            if (obj.get("quality")) |v| switch (v) {
                .string => |str| {
                    if (backend.Level.parse(str)) |level| config.quality = level;
                },
                else => {},
            };
            if (obj.get("complexity")) |v| switch (v) {
                .string => |str| {
                    if (backend.Level.parse(str)) |level| config.complexity = level;
                },
                else => {},
            };
            if (obj.get("format")) |v| switch (v) {
                .string => |str| {
                    if (backend.Format.parse(str)) |format| config.format = format;
                },
                else => {},
            };
            if (obj.get("frames")) |v| switch (v) {
                .integer => |n| {
                    if (n >= 2 and n <= 16) config.frames = @intCast(n);
                },
                else => {},
            };
            if (obj.get("frame_ms")) |v| switch (v) {
                .integer => |n| {
                    if (n >= 20 and n <= 60_000) config.frame_ms = @intCast(n);
                },
                else => {},
            };
        },
        else => {},
    }
}
