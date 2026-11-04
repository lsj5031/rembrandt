//! A log of what Rembrandt does, for when it misbehaves: each line is written
//! to a file as it happens, so a run's last line survives even an abrupt exit.
//! A GUI app's stderr goes nowhere on Windows; this is where it goes instead.
//!
//! `REMBRANDT_LOG=path` names another file; `REMBRANDT_LOG=off` disables it.
//! The default is `%LOCALAPPDATA%\Rembrandt\rembrandt.log` on Windows,
//! `~/Library/Logs/rembrandt.log` on macOS, and
//! `$XDG_STATE_HOME/rembrandt/rembrandt.log` (or the local state directory)
//! elsewhere. The previous run is kept as `.1`.
const std = @import("std");
const builtin = @import("builtin");

pub const env_name = "REMBRANDT_LOG";

const State = struct {
    file: ?std.Io.File = null,
    io: std.Io = undefined,
    /// Writes come from the view's thread and the HTTP callback's.
    lock: std.atomic.Value(bool) = .init(false),
    path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    path_len: usize = 0,

    fn acquire(self: *State) void {
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn release(self: *State) void {
        self.lock.store(false, .release);
    }
};

var state: State = .{};

/// The file this run logs to, once `init` opened it.
pub fn filePath() ?[]const u8 {
    if (state.file == null) return null;
    return state.path_buf[0..state.path_len];
}

/// Opens the log for this run. A log that cannot be opened leaves the app
/// running without one: a full disk must not take the app down.
pub fn init(process: std.process.Init) void {
    state.io = process.io;
    var raw_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const raw = resolve(process, &raw_buf) orelse return;
    var full_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full = absolute(process.io, raw, &full_buf);
    _ = openAt(process.io, full);
}

/// Opens `file_path` as this run's log, closing any log already open.
pub fn openAt(io: std.Io, file_path: []const u8) bool {
    close();
    state.io = io;
    if (std.fs.path.isAbsolute(file_path)) {
        if (std.fs.path.dirname(file_path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        rotate(io, file_path);
        state.file = std.Io.Dir.createFileAbsolute(io, file_path, .{}) catch null;
    } else {
        state.file = std.Io.Dir.cwd().createFile(io, file_path, .{}) catch null;
    }
    if (state.file == null) {
        std.debug.print("Rembrandt: can't write the log at {s}\n", .{file_path});
        return false;
    }
    state.path_len = @min(file_path.len, state.path_buf.len);
    @memcpy(state.path_buf[0..state.path_len], file_path[0..state.path_len]);
    std.debug.print("Rembrandt: logging to {s}\n", .{file_path});
    return true;
}

pub fn deinit() void {
    if (state.file == null) return;
    info("Rembrandt stopped", .{});
    close();
}

fn close() void {
    state.acquire();
    defer state.release();
    if (state.file) |f| f.close(state.io);
    state.file = null;
    state.path_len = 0;
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    write("INFO", fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    write("WARN", fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    write("ERR ", fmt, args);
}

/// `std.log`, into the same file: what Rembrandt and nanoui log as warnings
/// and errors lands here too, where a GUI app's stderr cannot.
pub fn stdLog(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime fmt: []const u8, args: anytype) void {
    if (state.file == null) {
        std.log.defaultLog(level, scope, fmt, args);
        return;
    }
    const name = switch (level) {
        .err => "ERR ",
        .warn => "WARN",
        .info => "INFO",
        .debug => "DBG ",
    };
    var buf: [880]u8 = undefined;
    const text = if (scope == .default)
        std.fmt.bufPrint(&buf, fmt, args) catch "(message too long)"
    else
        std.fmt.bufPrint(&buf, "{s}: " ++ fmt, .{@tagName(scope)} ++ args) catch "(message too long)";
    write(name, "{s}", .{text});
}

fn write(level: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (state.file == null) return;
    state.acquire();
    defer state.release();
    const file = state.file orelse return;
    var text_buf: [880]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, fmt, args) catch "(message too long)";
    var stamp_buf: [40]u8 = undefined;
    const when = stamp(&stamp_buf);
    var line_buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{s} {s} {s}\n", .{ when, level, text }) catch return;
    file.writeStreamingAll(state.io, line) catch {
        state.file = null;
    };
}

/// The time now, UTC, to the millisecond: "2026-11-04T10:34:06.123Z".
fn stamp(buf: []u8) []const u8 {
    const ms = std.Io.Clock.real.now(state.io).toMilliseconds();
    if (ms < 0) return "";
    const secs: u64 = @intCast(@divTrunc(ms, 1000));
    const millis: u64 = @intCast(@mod(ms, 1000));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
        millis,
    }) catch "";
}

/// Keeps the run before this one as `file_path.1`, so a fresh log never hides
/// how the last run ended.
fn rotate(io: std.Io, file_path: []const u8) void {
    var old_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const old = std.fmt.bufPrint(&old_buf, "{s}.1", .{file_path}) catch return;
    std.Io.Dir.deleteFileAbsolute(io, old) catch {};
    std.Io.Dir.renameAbsolute(file_path, old, io) catch {};
}

fn resolve(process: std.process.Init, buf: []u8) ?[]const u8 {
    const env_map = process.environ_map;
    if (env_map.get(env_name)) |given| {
        if (given.len == 0 or std.mem.eql(u8, given, "0") or std.ascii.eqlIgnoreCase(given, "off")) return null;
        return copy(buf, given);
    }
    if (builtin.os.tag == .windows) {
        if (env_map.get("LOCALAPPDATA")) |base| return join(buf, &.{ base, "Rembrandt", "rembrandt.log" });
        if (env_map.get("USERPROFILE")) |base| return join(buf, &.{ base, "rembrandt.log" });
    } else if (builtin.os.tag == .macos) {
        if (env_map.get("HOME")) |home| return join(buf, &.{ home, "Library", "Logs", "rembrandt.log" });
    } else {
        if (env_map.get("XDG_STATE_HOME")) |base| return join(buf, &.{ base, "rembrandt", "rembrandt.log" });
        if (env_map.get("HOME")) |home| return join(buf, &.{ home, ".local", "state", "rembrandt", "rembrandt.log" });
    }
    return "rembrandt.log";
}

fn copy(buf: []u8, s: []const u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

fn join(buf: []u8, parts: []const []const u8) ?[]const u8 {
    var len: usize = 0;
    for (parts, 0..) |part, i| {
        if (i > 0) {
            if (len == buf.len) return null;
            buf[len] = std.fs.path.sep;
            len += 1;
        }
        if (part.len > buf.len - len) return null;
        @memcpy(buf[len..][0..part.len], part);
        len += part.len;
    }
    return buf[0..len];
}

fn absolute(io: std.Io, file_path: []const u8, buf: []u8) []const u8 {
    if (std.fs.path.isAbsolute(file_path)) return file_path;
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().realPath(io, &cwd_buf) catch return file_path;
    return std.fmt.bufPrint(buf, "{s}{c}{s}", .{ cwd_buf[0..n], std.fs.path.sep, file_path }) catch file_path;
}
