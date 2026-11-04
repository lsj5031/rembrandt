//! Rembrandt's palette: warm paper, ink, stone, one deep pine accent.
const ui = @import("nanoui").ui;

pub const header_h: f32 = 72;
pub const caption_w: f32 = 138;

pub const ink = ui.Color.hex(0x1d1b17);
pub const stone = ui.Color.hex(0x6e675b);
pub const pine = ui.Color.hex(0x23483a);
pub const pine_hover = ui.Color.hex(0x2f5c4a);
pub const sage = ui.Color.hex(0x7f9b78);

pub const paper = ui.Theme{
    .dark = false,
    .background = ui.Color.hex(0xf8f5ee),
    .surface = ui.Color.hex(0xfffdf8),
    .surface_hover = ui.Color.hex(0xefeae0),
    .text = ink,
    .muted = stone,
    .border = ui.Color.hex(0xddd6c7),
    .accent = pine,
    .accent_hover = pine_hover,
    .accent_text = ui.Color.hex(0xfffdf8),
    .track = ui.Color.hex(0xe7e0d3),
    .knob = ui.Color.white,
    .danger = ui.Color.hex(0xb3452f),
    .success = ui.Color.hex(0x4f7a5b),
    .shadow = .{ .a = 0.12 },
};

pub const border = paper.border;
pub const surface = paper.surface;
pub const danger = paper.danger;
pub const thumb = ui.Color.hex(0xf1ece2);
pub const hover = ui.Color.hex(0xefe9de);
pub const selected = ui.Color.hex(0xf3f4ee);

/// The Rembrandt profile mark shared by the header, empty state, settings
/// sheet and app icon.
pub const mark_svg = @embedFile("mark.svg");
