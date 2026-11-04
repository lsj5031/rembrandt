//! Small controls shared by the header, composer, result and settings.
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;
const theme = @import("theme.zig");

pub const Caption = enum { minimize, maximize, close };

pub fn reduce(c: *ui.Context) bool {
    return c.reduced_motion or c.reduce_motion;
}

/// One press response for every clickable surface: 120ms, 0.97.
pub fn press(c: *ui.Context, enabled: bool) motion.Frame {
    const tr: motion.Transition = if (reduce(c))
        .instant
    else
        .{ .tween = .{ .duration = 0.12, .ease = .ease_out } };
    return motion.frame(c, .{
        .press = if (enabled) .{ .scale = 0.97 } else null,
        .transition = tr,
    });
}

/// The window's own buttons, at the header's right: minimize, maximize,
/// close. Windows draws no caption there (win_frame.zig). A press changes
/// the fill rather than scaling a window control.
pub fn captionButton(c: *ui.Context, kind: Caption) bool {
    const id = switch (kind) {
        .minimize => "caption-min",
        .maximize => "caption-max",
        .close => "caption-close",
    };
    ui.key(c, id);
    const d = ui.div(c).row().w(theme.caption_w / 3).h(theme.header_h).center();
    var out = switch (kind) {
        .close => d.hover(theme.danger.alpha(0.14)).control(),
        else => d.hover(theme.hover).control(),
    };
    const it = out.interaction();
    if (it.pressed) out = out.bg(if (kind == .close) theme.danger.alpha(0.22) else theme.selected);
    defer out.end();
    const hot = it.hovered or it.pressed;
    switch (kind) {
        .minimize => _ = c.leaf(.{ .width = .{ .px = 10 }, .height = .{ .px = 1 }, .background = theme.stone }, .none, null),
        .maximize => _ = c.leaf(.{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .border = theme.stone, .border_width = 1 }, .none, null),
        .close => ui.icon(c, "xmark", .{ .size = 10, .color = if (hot) theme.danger else theme.stone }),
    }
    return out.clicked();
}

pub fn primaryButton(c: *ui.Context, enabled: bool) bool {
    const f = press(c, enabled);
    var b = ui.div(c).row().wFull().h(48).itemsCenter().justifyCenter().gap(8).rounded(12)
        .bg(theme.pine).opacity(if (enabled) 1 else 0.38).control().motion(f);
    if (enabled) b = b.hover(theme.pine_hover);
    defer b.end();
    const clicked = if (enabled) b.clicked() else false;
    ui.text(c, "Generate", .{ .size = 16, .weight = .medium, .color = theme.paper.accent_text });
    ui.icon(c, "arrow.right", .{ .size = 16, .color = theme.paper.accent_text });
    return enabled and clicked;
}

/// A settings action with the same restrained press response as Generate.
pub fn settingsButton(c: *ui.Context, label: []const u8, primary: bool) bool {
    const f = press(c, true);
    var b = ui.div(c).row().itemsCenter().justifyCenter().h(32).px(12).rounded(8)
        .motion(f).control();
    b = if (primary) b.bg(theme.pine).hover(theme.pine_hover) else b.hover(theme.hover);
    defer b.end();
    const clicked = b.clicked();
    ui.text(c, label, .{
        .size = 13,
        .weight = .medium,
        .color = if (primary) theme.paper.accent_text else theme.ink,
    });
    return clicked;
}

pub fn smallLabel(c: *ui.Context, text: []const u8) void {
    ui.text(c, text, .{ .size = 10, .weight = .medium, .color = theme.stone });
}

pub fn settingsLabel(c: *ui.Context, text: []const u8) void {
    ui.text(c, text, .{ .size = 10, .weight = .medium, .color = theme.stone });
}

pub fn chip(c: *ui.Context, label: []const u8, chevron: bool) bool {
    const f = press(c, true);
    const d = ui.div(c).row().itemsCenter().gap(5).px(10).py(6).rounded(8)
        .border(theme.border).borderW(1).motion(f).hover(theme.hover);
    defer d.end();
    ui.text(c, label, .{ .size = 12, .color = theme.stone });
    if (chevron) ui.icon(c, "chevron.down", .{ .size = 9, .color = theme.stone });
    return d.clicked();
}

pub fn link(c: *ui.Context, label: []const u8) bool {
    const f = press(c, true);
    const d = ui.div(c).row().px(4).py(2).rounded(5).motion(f).hover(theme.hover);
    defer d.end();
    ui.text(c, label, .{ .size = 12, .weight = .medium, .color = theme.pine });
    return d.clicked();
}
