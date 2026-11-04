//! Rembrandt's state and its view: one 1240×820 window, a prompt on the
//! left, the image on the right, and the backend behind both. The header is
//! the title bar: Windows draws no caption (win_frame.zig).
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;
const backend = @import("backend.zig");
const log = @import("log.zig");
const settings_store = @import("settings_store.zig");
const theme = @import("theme.zig");
const controls = @import("controls.zig");
const references = @import("references.zig");
const Caption = controls.Caption;
const captionButton = controls.captionButton;
const primaryButton = controls.primaryButton;
const reduce = controls.reduce;
const smallLabel = controls.smallLabel;
const settingsLabel = controls.settingsLabel;
const settingsButton = controls.settingsButton;
const chip = controls.chip;
const link = controls.link;

pub const State = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    config: backend.Config,
    /// `%APPDATA%\Rembrandt\settings.json`; null when there is no data dir.
    config_path: ?[]u8 = null,
    prompt: ui.TextBuffer = .{},
    refs: references.List = .{},
    ref_action: controls.RefAction = .none,
    /// Caller-owned override for isolated generation checks; null uses Documents.
    output_dir: ?[]const u8 = null,

    history: [8]backend.Item = undefined,
    count: usize = 0,
    selected: usize = 0,

    generating: bool = false,
    started_at: f64 = 0,
    elapsed: f64 = 0,

    error_text: [512]u8 = undefined,
    error_len: usize = 0,

    show_settings: bool = false,
    url_buf: ui.TextBuffer = .{},
    model_buf: ui.TextBuffer = .{},
    key_buf: ui.TextBuffer = .{},

    window: ?*nanoui.Window = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, env: anytype) !State {
        var s: State = .{
            .gpa = gpa,
            .io = io,
            .config = try backend.Config.init(gpa, env),
        };
        s.config_path = settings_store.path(gpa) catch null;
        if (s.config_path) |path| settings_store.load(gpa, io, path, &s.config) catch {};
        log.info("settings: base={s} model={s} size={s}", .{ s.config.base_url, s.config.model, s.config.size.api() });
        if (env.get("REMBRANDT_PROMPT")) |p| s.prompt.set(p);
        s.loadDemo(env) catch {};
        s.refs.loadEnv(gpa, io, env);
        log.info("references loaded: {d}", .{s.refs.items.items.len});
        return s;
    }

    pub fn initDefault(gpa: std.mem.Allocator, io: std.Io) !State {
        return .{
            .gpa = gpa,
            .io = io,
            .config = try backend.Config.defaults(gpa),
        };
    }

    pub fn deinit(s: *State) void {
        for (0..s.count) |i| {
            s.gpa.free(s.history[i].bytes);
            s.gpa.free(s.history[i].name);
            s.gpa.free(s.history[i].path);
        }
        s.config.deinit(s.gpa);
        s.refs.deinit(s.gpa);
        if (s.config_path) |p| s.gpa.free(p);
        s.prompt.deinit();
        s.url_buf.deinit();
        s.model_buf.deinit();
        s.key_buf.deinit();
    }

    pub fn view(s: *State, c: *ui.Context) void {
        const action = s.ref_action;
        s.ref_action = .none;
        s.referenceAction(action, c);
        c.theme = theme.paper;
        c.title_bar_height = theme.header_h;
        if (s.generating) {
            s.elapsed = ui.clock.now() - s.started_at;
            c.animationFrame();
        }
        const root = ui.div(c).column().sizeFull().bg(theme.paper.background);
        defer root.end();
        s.header(c);
        ui.divider(c);
        s.body(c);
        ui.divider(c);
        s.footer(c);
        // Windows draws no caption: the header is the title bar, and its
        // right end carries the window's buttons.
        if (comptime builtin.os.tag == .windows) s.caption(c);
        // Always called: motion.present keeps drawing the exit after close.
        s.settings(c);
    }

    fn header(s: *State, c: *ui.Context) void {
        // macOS traffic lights sit over the header's left end.
        const left: f32 = if (comptime builtin.os.tag == .macos) 84 else 36;
        const h = ui.div(c).row().wFull().h(theme.header_h).pl(left).pr(36).itemsCenter().gap(12);
        defer h.end();
        _ = ui.svg(c, .{ .key = "rembrandt.mark", .bytes = theme.mark_svg, .size = 26 });
        ui.text(c, "Rembrandt", .{ .size = 18, .weight = .semibold, .color = theme.ink });
        ui.spacer(c);

        const status = ui.div(c).row().itemsCenter().gap(6);
        ui.div(c).w(6).h(6).roundedFull().bg(theme.sage).end();
        ui.text(c, if (s.config.isLocal()) "local" else "remote", .{ .size = 12, .color = theme.stone });
        status.end();

        const menu_f = controls.press(c, true);
        const menu = ui.div(c).w(30).h(30).itemsCenter().justifyCenter().rounded(6).motion(menu_f).hover(theme.hover);
        if (menu.clicked()) s.openSettings();
        ui.icon(c, "ellipsis.circle", .{ .size = 16, .color = theme.stone });
        menu.end();

        // Make room for the window buttons the fixed caption draws.
        if (comptime builtin.os.tag == .windows) {
            _ = c.leaf(.{ .width = .{ .px = theme.caption_w } }, .none, null);
        }
    }

    fn body(s: *State, c: *ui.Context) void {
        const b = ui.div(c).row().wFull().grow().px(36).py(28).gap(28);
        defer b.end();
        s.composer(c);
        s.preview(c);
    }

    fn composer(s: *State, c: *ui.Context) void {
        const col = ui.div(c).column().w(420).gap(12);
        defer col.end();
        c.acceptDrop(col.index);
        // Apply drops after drawing, so retained image bytes live through this frame.
        defer if (c.dropAt(col.index)) |drop| {
            var failure: ?anyerror = null;
            for (drop.urls) |url| {
                const path = references.pathFromUrl(s.gpa, url) catch |e| {
                    failure = e;
                    continue;
                } orelse continue;
                defer s.gpa.free(path);
                s.refs.addPath(s.gpa, s.io, path) catch |e| {
                    failure = e;
                };
            }
            if (failure) |e| s.refs.setError(e);
            c.changed = true;
        };

        smallLabel(c, "PROMPT");
        const result = ui.textArea(c, &s.prompt, .{
            .placeholder = "Describe an image…",
            .size = 24,
            .min_lines = 3,
            .max_lines = 5,
            .bare = true,
            .color = theme.ink,
        });
        if (result.submitted and !s.generating) s.generate();

        s.ref_action = controls.referenceStrip(c, s.refs.items.items, s.refs.limits.max_refs);
        // ui.image retains its bytes through paint; free removed refs next frame.
        if (s.ref_action != .none) c.changed = true;
        if (s.refs.error_len > 0) ui.text(c, s.refs.error_text[0..s.refs.error_len], .{ .size = 11, .color = theme.danger });
        if (s.generating) ui.text(c, "Reference changes apply to the next generation.", .{ .size = 11, .color = theme.stone });
        ui.divider(c);

        const chips = ui.div(c).row().itemsCenter().gap(8);

        var model_buf: [32]u8 = undefined;
        if (chip(c, s.config.modelShort(&model_buf), true)) s.openSettings();
        if (chip(c, s.config.size.label(), true)) s.cycleSize();
        if (link(c, "+ Reference")) s.chooseReferences(c);
        ui.text(c, "1 image", .{ .size = 12, .color = theme.stone });
        chips.end();

        if (primaryButton(c, !s.generating and s.hasPrompt())) s.generate();

        smallLabel(c, "RECENT");
        if (s.count == 0) {
            ui.text(c, "No images yet", .{ .size = 12, .color = theme.stone });
            ui.text(c, "Generate one to start a history.", .{ .size = 11, .color = theme.stone });
        } else {
            // Room for three, scroll for the rest.
            ui.scroll(c, .{ .width = .fill, .max_height = 190, .gap = 6 });
            defer ui.end(c);
            for (0..s.count) |i| s.historyRow(c, i);
        }
    }

    fn historyRow(s: *State, c: *ui.Context, idx: usize) void {
        const it = &s.history[idx];
        ui.key(c, it.name);
        const row_f = controls.press(c, true);
        const row = ui.div(c).row().wFull().p(6).gap(10).itemsCenter().rounded(10)
            .border(if (idx == s.selected) theme.pine else theme.border)
            .borderW(1)
            .bg(if (idx == s.selected) theme.selected else theme.paper.background)
            .motion(row_f).hover(theme.hover);
        defer row.end();
        if (row.clicked()) {
            s.selected = idx;
            c.changed = true;
        }

        const thumb = ui.div(c).w(40).h(40).rounded(6).bg(theme.thumb).clip().itemsCenter().justifyCenter();
        _ = ui.image(c, .{ .key = it.name, .bytes = it.bytes, .max_width = 40, .max_height = 40, .radius = 6, .scale = 1 });
        thumb.end();

        const meta = ui.div(c).column().gap(1).justifyCenter();
        defer meta.end();
        ui.text(c, it.name, .{ .size = 12, .weight = .medium, .color = theme.ink });
        ui.text(c, if (it.demo) "demo preview" else c.print("{d:.1}s", .{it.secs}), .{ .size = 10, .color = theme.stone });
    }

    fn preview(s: *State, c: *ui.Context) void {
        const col = ui.div(c).column().grow().gap(10);
        defer col.end();

        const frame = ui.div(c).wFull().h(467).rounded(12).bg(theme.thumb)
            .border(theme.border).borderW(1).clip().itemsCenter().justifyCenter();

        if (s.generating) {
            const box = ui.div(c).column().itemsCenter().gap(6);
            defer box.end();
            const line = ui.div(c).row().itemsCenter().gap(8);
            defer line.end();
            var dot = ui.div(c).w(7).h(7).roundedFull().bg(theme.pine);
            if (!reduce(c)) {
                dot = dot.motion(motion.keyframes(c, .{
                    .values = &.{
                        .{ .opacity = 0.35, .scale = 0.9 },
                        .{ .opacity = 1, .scale = 1.08 },
                        .{ .opacity = 0.35, .scale = 0.9 },
                    },
                    .duration = 1.3,
                    .repeat = null,
                }));
            }
            dot.end();
            ui.text(c, "Generating…", .{ .size = 16, .weight = .medium, .color = theme.ink });
            ui.text(c, c.print("{d:.0}s", .{s.elapsed}), .{ .size = 12, .color = theme.stone });
        } else if (s.error_len > 0) {
            const box = ui.div(c).column().w(560).itemsCenter().gap(8);
            defer box.end();
            ui.text(c, "That didn't work", .{ .size = 14, .weight = .semibold, .color = theme.ink });
            ui.text(c, s.error_text[0..s.error_len], .{ .size = 12, .color = theme.danger, .wrap = true });
        } else if (s.count > 0) {
            const it = &s.history[s.selected];
            ui.key(c, it.name);
            const reveal = if (reduce(c))
                motion.frame(c, .{ .transition = .instant })
            else
                motion.frame(c, .{
                    .initial = .{ .opacity = 0, .scale = 0.985 },
                    .transition = .{ .tween = .{ .duration = 0.22, .ease = .ease_out } },
                });
            const wrap = ui.div(c).sizeFull().itemsCenter().justifyCenter().motion(reveal);
            defer wrap.end();
            _ = ui.image(c, .{ .key = it.name, .bytes = it.bytes, .max_width = 700, .max_height = 467, .radius = 12, .scale = 1 });
        } else {
            _ = ui.svg(c, .{ .key = "rembrandt.empty", .bytes = theme.mark_svg, .size = 58 });
            ui.text(c, "Your image will appear here", .{ .size = 13, .color = theme.stone });
            ui.text(c, "Write a prompt and press Generate.", .{ .size = 11, .color = theme.stone });
        }
        frame.end();

        if (s.count > 0 and s.error_len == 0) {
            const it = &s.history[s.selected];
            const meta = ui.div(c).row().wFull().itemsCenter().gap(12);

            const info = ui.div(c).column().gap(2);
            ui.text(c, it.name, .{ .size = 13, .weight = .medium, .color = theme.ink });
            const mb = @as(f64, @floatFromInt(it.bytes.len)) / (1024.0 * 1024.0);
            ui.text(c, c.print("{d} × {d} · {d:.2} MB", .{ it.width, it.height, mb }), .{ .size = 11, .color = theme.stone });
            info.end();

            ui.spacer(c);
            if (link(c, "Use as reference")) {
                s.refs.addBytes(s.gpa, it.name, it.bytes) catch |e| s.refs.setError(e);
                c.changed = true;
            }
            if (link(c, "Copy path")) nanoui.clipboard.writeText(it.path);
            if (link(c, "Open")) _ = nanoui.shell.openPath(it.path);
            meta.end();

            const timing = ui.div(c).row().wFull().justifyEnd();
            defer timing.end();
            ui.text(c, if (it.demo) "demo preview" else c.print("{d:.1}s · {d} tokens", .{ it.secs, it.tokens }), .{ .size = 11, .color = theme.stone, .mono = true });
        }
    }

    fn footer(s: *State, c: *ui.Context) void {
        const f = ui.div(c).row().wFull().h(48).px(36).itemsCenter().gap(8);
        defer f.end();
        ui.text(c, s.config.endpoint(), .{ .size = 11, .mono = true, .color = theme.stone });
        ui.spacer(c);
        ui.div(c).w(6).h(6).roundedFull().bg(theme.sage).end();
        ui.text(c, s.config.provider(), .{ .size = 11, .color = theme.stone });
    }

    fn settings(s: *State, c: *ui.Context) void {
        if (s.show_settings and c.input.key == .escape) {
            s.show_settings = false;
            c.changed = true;
        }

        const calm = reduce(c);
        const veil_tr: motion.Transition = .{ .tween = .{
            .duration = if (s.show_settings) (if (calm) 0.12 else 0.15) else (if (calm) 0.10 else 0.10),
            .ease = .ease_out,
        } };
        if (motion.present(c, "settings.veil", s.show_settings, .{
            .initial = .{ .opacity = 0 },
            .exit = .{ .opacity = 0 },
            .transition = veil_tr,
        })) |veil_frame| {
            const veil = ui.div(c).fixed().sizeFull().layer(10).bg(theme.ink.alpha(0.10))
                .control().motion(veil_frame);
            _ = veil.interaction();
            veil.end();
            // The backdrop blocks the page; it is not a control.
            c.cursor_hand = false;
        }

        const card_tr: motion.Transition = .{ .tween = .{
            .duration = if (s.show_settings) (if (calm) 0.12 else 0.18) else (if (calm) 0.10 else 0.13),
            .ease = .ease_out,
        } };
        const card_initial: motion.Target = if (calm)
            .{ .opacity = 0 }
        else
            .{ .opacity = 0, .x = 24 };
        const card_exit: motion.Target = if (calm)
            .{ .opacity = 0 }
        else
            .{ .opacity = 0, .x = 16 };
        const card_frame = motion.present(c, "settings.card", s.show_settings, .{
            .initial = card_initial,
            .exit = card_exit,
            .transition = card_tr,
        }) orelse return;
        const card = ui.div(c).fixed().offset(c.size.w - 404, 84).w(380).layer(11)
            .column().p(18).gap(9).bg(theme.paper.surface)
            .rounded(14).border(theme.border).borderW(1).shadowMd().motion(card_frame);
        const card_rect = c.rects.get(card.id());
        defer card.end();

        const head = ui.div(c).row().itemsCenter().gap(8);
        _ = ui.svg(c, .{ .key = "rembrandt.settings", .bytes = theme.mark_svg, .size = 18 });
        ui.text(c, "Backend", .{ .size = 15, .weight = .semibold, .color = theme.ink });
        head.end();
        ui.text(c, "Any OpenAI-compatible image service.", .{ .size = 10, .color = theme.stone });

        settingsLabel(c, "BASE URL");
        _ = ui.textField(c, &s.url_buf, .{ .placeholder = "http://127.0.0.1:3425/v1", .width = .fill, .size = 13 });
        settingsLabel(c, "MODEL");
        _ = ui.textField(c, &s.model_buf, .{ .placeholder = "your-model", .width = .fill, .size = 13 });
        settingsLabel(c, "API KEY");
        _ = ui.textField(c, &s.key_buf, .{ .placeholder = "Optional API key", .width = .fill, .size = 13, .password = true });
        ui.text(c, "The key stays in memory; the rest is kept.", .{ .size = 10, .color = theme.stone });

        const buttons = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer buttons.end();
        ui.spacer(c);
        if (settingsButton(c, "Cancel", false)) s.show_settings = false;
        if (settingsButton(c, "Save", true)) s.saveSettings();

        if (s.show_settings and c.input.pressed) {
            const inside = if (card_rect) |r| r.contains(c.input.mouse) else true;
            if (!inside) {
                s.show_settings = false;
                c.changed = true;
            }
        }
    }

    /// The window's own buttons, at the header's right: minimize, maximize,
    /// close. Windows draws no caption there (win_frame.zig).
    fn caption(s: *State, c: *ui.Context) void {
        const r = ui.div(c).fixed().offset(c.size.w - theme.caption_w, 0).w(theme.caption_w).h(theme.header_h).row();
        defer r.end();
        if (captionButton(c, .minimize)) {
            if (s.window) |window| window.minimize();
        }
        if (captionButton(c, .maximize)) {
            if (s.window) |window| window.zoom();
        }
        if (captionButton(c, .close)) {
            if (s.window) |window| window.close();
        }
    }

    fn openSettings(s: *State) void {
        s.show_settings = true;
        s.url_buf.set(s.config.base_url);
        s.model_buf.set(s.config.model);
        s.key_buf.set(s.config.api_key);
    }

    fn saveSettings(s: *State) void {
        s.config.setBase(s.gpa, s.url_buf.text()) catch {};
        s.config.setModel(s.gpa, s.model_buf.text()) catch {};
        s.config.setKey(s.gpa, s.key_buf.text()) catch {};
        if (s.config_path) |path| settings_store.save(s.gpa, s.io, path, &s.config) catch |e| log.warn("settings save failed: {t}", .{e});
        log.info("settings applied: base={s} model={s} size={s}", .{ s.config.base_url, s.config.model, s.config.size.api() });
        s.show_settings = false;
    }

    pub fn cycleSize(s: *State) void {
        s.config.size = s.config.size.cycle();
        if (s.config_path) |path| settings_store.save(s.gpa, s.io, path, &s.config) catch {};
    }

    pub fn hasPrompt(s: *State) bool {
        return std.mem.trim(u8, s.prompt.text(), " \t\r\n").len > 0;
    }

    fn loadDemo(s: *State, env: anytype) !void {
        const demo_path = env.get("REMBRANDT_DEMO_IMAGE") orelse return;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(s.io, demo_path, s.gpa, .limited(64 << 20));
        errdefer s.gpa.free(bytes);
        const dims = backend.pngSize(bytes) orelse return error.NotPng;
        const name = try s.gpa.dupe(u8, basename(demo_path));
        errdefer s.gpa.free(name);
        const path = try s.gpa.dupe(u8, demo_path);
        s.addItem(.{
            .bytes = bytes,
            .name = name,
            .path = path,
            .width = dims.width,
            .height = dims.height,
            .tokens = 0,
            .secs = 0,
            .demo = true,
        });
    }

    pub const generate = @import("generation.zig").generate;

    fn chooseReferences(s: *State, c: *ui.Context) void {
        const paths = nanoui.dialog.open(s.gpa, .{ .title = "Add reference images", .button = "Add", .extensions = &.{ "png", "jpg", "jpeg", "webp" }, .multiple = true }) catch |e| {
            s.refs.setError(e);
            c.changed = true;
            return;
        } orelse return;
        defer nanoui.dialog.freePaths(s.gpa, paths);
        var failure: ?anyerror = null;
        for (paths) |path| s.refs.addPath(s.gpa, s.io, path) catch |e| {
            failure = e;
        };
        if (failure) |e| s.refs.setError(e);
        c.changed = true;
    }

    fn referenceAction(s: *State, action: controls.RefAction, c: *ui.Context) void {
        switch (action) {
            .none => return,
            .add => s.chooseReferences(c),
            .remove => |i| s.refs.remove(s.gpa, i),
            .clear => s.refs.clear(s.gpa),
        }
        c.changed = true;
    }

    pub fn addItem(s: *State, item: backend.Item) void {
        if (s.count == s.history.len) {
            const oldest = s.history[s.count - 1];
            s.gpa.free(oldest.bytes);
            s.gpa.free(oldest.name);
            s.gpa.free(oldest.path);
            s.count -= 1;
        }
        var i = s.count;
        while (i > 0) : (i -= 1) s.history[i] = s.history[i - 1];
        s.history[0] = item;
        s.count += 1;
        s.selected = 0;
    }

    pub fn setError(s: *State, msg: []const u8) void {
        const n = @min(msg.len, s.error_text.len);
        @memcpy(s.error_text[0..n], msg[0..n]);
        s.error_len = n;
        log.err("error: {s}", .{s.error_text[0..n]});
    }

    pub fn clearError(s: *State) void {
        s.error_len = 0;
    }
};

fn basename(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/' or path[i - 1] == '\\') return path[i..];
    }
    return path;
}
