const std = @import("std");
const vaxis = @import("vaxis");
const Theme = @import("dialog.zig").Theme;
const Glyphs = @import("dialog.zig").Glyphs;

pub const GlyphMode = enum { rounded, square, nerd, ascii };

pub const Palette = struct {
    theme: Theme,
    foreground: vaxis.Color,
    muted: vaxis.Color,
    accent: vaxis.Color,
    border: vaxis.Color,
    panel_background: vaxis.Color,
    app_background: vaxis.Color,
    field_background: vaxis.Color,
    selected_foreground: vaxis.Color,
    selected_background: vaxis.Color,
    monochrome: bool,

    pub fn init(vx: *const vaxis.Vaxis, requested: Theme) Palette {
        const env = vx.env_map;
        const term = env.get("TERM") orelse "";
        const no_color = vx.caps.no_color or envHasValue(env, "NO_COLOR");
        const theme: Theme = if (no_color) .mono else switch (requested) {
            .auto => if (std.ascii.eqlIgnoreCase(term, "linux")) .classic else if (std.ascii.eqlIgnoreCase(term, "dumb")) .mono else if (modernTerminal(vx)) .aurora else .classic,
            else => requested,
        };
        const mono = theme == .mono;

        return switch (theme) {
            .classic => .{
                .theme = theme,
                .app_background = .default,
                .foreground = color(vx, mono, .{ 238, 238, 238 }, 7),
                .muted = color(vx, mono, .{ 190, 204, 224 }, 7),
                .accent = color(vx, mono, .{ 255, 220, 112 }, 11),
                .border = color(vx, mono, .{ 88, 195, 230 }, 6),
                .panel_background = color(vx, mono, .{ 18, 42, 104 }, 4),
                .field_background = color(vx, mono, .{ 18, 42, 104 }, 4),
                .selected_foreground = color(vx, mono, .{ 12, 24, 50 }, 0),
                .selected_background = color(vx, mono, .{ 105, 210, 238 }, 14),
                .monochrome = false,
            },
            .aurora => .{
                .theme = theme,
                .app_background = color(vx, mono, .{ 9, 13, 24 }, 0),
                .foreground = color(vx, mono, .{ 226, 234, 246 }, 15),
                .muted = color(vx, mono, .{ 137, 151, 176 }, 8),
                .accent = color(vx, mono, .{ 94, 234, 212 }, 14),
                .border = color(vx, mono, .{ 82, 143, 176 }, 6),
                .panel_background = color(vx, mono, .{ 17, 22, 35 }, 0),
                .field_background = color(vx, mono, .{ 31, 41, 59 }, 8),
                .selected_foreground = color(vx, mono, .{ 238, 247, 255 }, 15),
                .selected_background = color(vx, mono, .{ 36, 55, 77 }, 4),
                .monochrome = false,
            },
            .sunset => .{
                .theme = theme,
                .foreground = color(vx, mono, .{ 250, 235, 220 }, 15),
                .app_background = color(vx, mono, .{ 23, 13, 27 }, 0),
                .muted = color(vx, mono, .{ 184, 151, 137 }, 8),
                .accent = color(vx, mono, .{ 255, 185, 112 }, 11),
                .border = color(vx, mono, .{ 224, 115, 119 }, 9),
                .panel_background = color(vx, mono, .{ 37, 24, 39 }, 0),
                .field_background = color(vx, mono, .{ 57, 34, 49 }, 8),
                .selected_foreground = color(vx, mono, .{ 255, 248, 239 }, 15),
                .selected_background = color(vx, mono, .{ 93, 43, 63 }, 1),
                .monochrome = false,
            },
            .mono, .auto => .{
                .theme = .mono,
                .app_background = .default,
                .foreground = .default,
                .muted = .default,
                .accent = .default,
                .border = .default,
                .panel_background = .default,
                .field_background = .default,
                .selected_foreground = .default,
                .selected_background = .default,
                .monochrome = true,
            },
        };
    }
};

pub fn resolveGlyphs(vx: *const vaxis.Vaxis, requested: Glyphs) GlyphMode {
    switch (requested) {
        .ascii => return .ascii,
        .rounded => return .rounded,
        .square => return .square,
        .nerd => return .nerd,
        .auto => {},
    }

    const env = vx.env_map;
    if (env.get("ZIPTAIL_GLYPHS")) |preference| {
        if (std.ascii.eqlIgnoreCase(preference, "nerd")) return .nerd;
        if (std.ascii.eqlIgnoreCase(preference, "ascii")) return .ascii;
        if (std.ascii.eqlIgnoreCase(preference, "square")) return .square;
        if (std.ascii.eqlIgnoreCase(preference, "rounded")) return .rounded;
    }
    const term = env.get("TERM") orelse "";
    if (std.ascii.eqlIgnoreCase(term, "linux") or std.ascii.eqlIgnoreCase(term, "dumb")) return .ascii;
    return .rounded;
}

pub fn borderGlyphs(glyphs: GlyphMode) vaxis.Window.BorderOptions.Glyphs {
    return switch (glyphs) {
        .rounded, .nerd => .single_rounded,
        .square => .single_square,
        .ascii => .{ .custom = .{ "+", "-", "+", "|", "+", "+" } },
    };
}

pub fn logo(glyphs: GlyphMode) []const u8 {
    return switch (glyphs) {
        .nerd => "\u{f120}",
        .ascii => "Z",
        else => "✦",
    };
}

pub fn spinner(glyphs: GlyphMode, frame: usize) []const u8 {
    const frames = switch (glyphs) {
        .nerd => [_][]const u8{ "\u{f111}", "\u{f10c}", "\u{f111}", "\u{f10c}" },
        .ascii => [_][]const u8{ "|", "/", "-", "\\" },
        else => [_][]const u8{ "◜", "◝", "◞", "◟" },
    };
    return frames[frame % frames.len];
}

pub fn menuMarker(glyphs: GlyphMode, selected: bool) []const u8 {
    return switch (glyphs) {
        .nerd => if (selected) "\u{f105} " else "  ",
        .ascii => if (selected) "> " else "  ",
        else => if (selected) "› " else "  ",
    };
}

pub fn checkMarker(glyphs: GlyphMode, checked: bool) []const u8 {
    return switch (glyphs) {
        .nerd => if (checked) "\u{f00c} " else "\u{f096} ",
        .ascii => if (checked) "[x] " else "[ ] ",
        else => if (checked) "☑ " else "☐ ",
    };
}

pub fn radioMarker(glyphs: GlyphMode, checked: bool) []const u8 {
    return switch (glyphs) {
        .nerd => if (checked) "\u{f192} " else "\u{f10c} ",
        .ascii => if (checked) "(o) " else "( ) ",
        else => if (checked) "● " else "○ ",
    };
}

pub fn barGlyph(glyphs: GlyphMode, filled: bool) []const u8 {
    return switch (glyphs) {
        .ascii => if (filled) "=" else "-",
        else => if (filled) "█" else "░",
    };
}

fn color(vx: *const vaxis.Vaxis, mono: bool, rgb: [3]u8, indexed: u8) vaxis.Color {
    if (mono or vx.caps.no_color) return .default;
    return if (vx.caps.rgb) .{ .rgb = rgb } else .{ .index = indexed };
}

pub fn modernLayout(vx: *const vaxis.Vaxis, requested: Theme) bool {
    if (requested == .classic) return false;
    if (requested == .aurora or requested == .sunset) return true;
    const term = vx.env_map.get("TERM") orelse "";
    if (std.ascii.eqlIgnoreCase(term, "linux") or std.ascii.eqlIgnoreCase(term, "dumb")) return false;
    return modernTerminal(vx);
}

fn modernTerminal(vx: *const vaxis.Vaxis) bool {
    if (vx.caps.rgb or vx.caps.kitty_graphics or vx.caps.kitty_keyboard) return true;
    const env = vx.env_map;
    const term = env.get("TERM") orelse "";
    if (std.mem.indexOf(u8, term, "256color") != null) return true;
    inline for (&.{ "GHOSTTY_RESOURCES_DIR", "KITTY_WINDOW_ID", "WEZTERM_PANE", "VSCODE_IPC_HOOK_CLI", "WT_SESSION" }) |key| {
        if (env.get(key)) |_| return true;
    }
    if (env.get("COLORTERM")) |value| {
        if (std.ascii.eqlIgnoreCase(value, "truecolor") or std.ascii.eqlIgnoreCase(value, "24bit")) return true;
    }
    if (env.get("TERM_PROGRAM")) |program| {
        inline for (&.{ "vscode", "ghostty", "kitty", "wezterm", "alacritty", "iTerm.app", "Apple_Terminal", "Hyper" }) |known| {
            if (std.ascii.eqlIgnoreCase(program, known)) return true;
        }
    }
    return false;
}

fn envHasValue(env: *std.process.Environ.Map, key: []const u8) bool {
    const value = env.get(key) orelse return false;
    return value.len != 0;
}
