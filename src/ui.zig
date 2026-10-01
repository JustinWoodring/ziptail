const std = @import("std");
const vaxis = @import("vaxis");
const Dialog = @import("dialog.zig").Dialog;
const presentation = @import("presentation.zig");
const deck_mod = @import("deck.zig");
pub const Result = enum { accepted, cancelled, escaped };

pub const Outcome = struct {
    result: Result,
    selected: usize,
    checks: []const bool,
    input: []const u8,
    form_values: []const []const u8,
};

const FormState = struct {
    value: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
};

const State = struct {
    selected: usize = 0,
    checks: []bool,
    input: std.ArrayList(u8) = .empty,
    input_cursor: usize = 0,
    form_fields: []FormState,
    active_field: usize = 0,
    presentation_screen: usize = 0,
    transition_frame: u8 = 5,
    transition_direction: i2 = 0,
    yes_selected: bool = true,
    scroll_offset: usize = 0,
    gauge_percent: u8 = 0,
    gauge_text: []const u8 = "",
    result: ?Result = null,
};

const GaugeUpdate = struct {
    percent: ?u8 = null,
    text: ?[]const u8 = null,
};

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    mouse: vaxis.Mouse,
    tick,
    gauge_update: GaugeUpdate,
    gauge_done,
};
const Layout = struct {
    modern: bool,
    panel_x: i17,
    panel_y: i17,
    panel_width: u16,
    panel_height: u16,
    sidebar_width: u16,
};

fn computeLayout(vx: *vaxis.Vaxis, dialog: *const Dialog) Layout {
    const screen = vx.window();
    const modern = presentation.modernLayout(vx, dialog.theme) and screen.width >= 72 and screen.height >= 18;
    if (modern) {
        const main_left: u16 = 22;
        const available_width = screen.width -| main_left -| 2;
        const max_card_width = @min(@as(u16, 112), available_width);
        const panel_width = @min(available_width, @max(dialog.width orelse available_width, max_card_width));
        const available_height = screen.height -| 6;
        const panel_height = @min(available_height, @max(dialog.height orelse available_height, 16));
        const panel_x = if (dialog.top_left) main_left else main_left + (available_width -| panel_width) / 2;
        const panel_y: u16 = if (dialog.top_left) 3 else 3 + (available_height -| panel_height) / 2;
        return .{
            .modern = true,
            .panel_x = @intCast(panel_x),
            .panel_y = @intCast(panel_y),
            .panel_width = panel_width,
            .panel_height = panel_height,
            .sidebar_width = 20,
        };
    }

    const panel_width = @min(screen.width, dialog.width orelse screen.width);
    const panel_height = @min(screen.height, dialog.height orelse screen.height);
    const panel_x = if (dialog.top_left) @min(@as(u16, 2), screen.width - panel_width) else (screen.width - panel_width) / 2;
    const top_margin: u16 = if (dialog.backtitle != null) 2 else 1;
    const panel_y = if (dialog.top_left) @min(top_margin, screen.height - panel_height) else (screen.height - panel_height) / 2;
    return .{
        .modern = false,
        .panel_x = @intCast(panel_x),
        .panel_y = @intCast(panel_y),
        .panel_width = panel_width,
        .panel_height = panel_height,
        .sidebar_width = 0,
    };
}

fn transmitImagePath(vx: *vaxis.Vaxis, io: std.Io, allocator: std.mem.Allocator, tty: *std.Io.Writer, path: []const u8) !vaxis.Image {
    var read_buffer: [1024 * 1024]u8 = undefined;
    var decoded = try vaxis.zigimg.Image.fromFilePath(allocator, io, path, &read_buffer);
    defer decoded.deinit(allocator);
    return vx.transmitImage(allocator, tty, &decoded, .rgba);
}

fn sanitizeTerminalText(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte == 0x1b) {
            index += 1;
            if (index < text.len and text[index] == '[') {
                index += 1;
                while (index < text.len) : (index += 1) {
                    if (text[index] >= 0x40 and text[index] <= 0x7e) {
                        index += 1;
                        break;
                    }
                }
            } else if (index < text.len and text[index] == ']') {
                index += 1;
                while (index < text.len) : (index += 1) {
                    if (text[index] == 0x07) {
                        index += 1;
                        break;
                    }
                    if (text[index] == 0x1b and index + 1 < text.len and text[index + 1] == '\\') {
                        index += 2;
                        break;
                    }
                }
            } else if (index < text.len) {
                index += 1;
            }
            continue;
        }
        if ((byte < 0x20 and byte != '\n' and byte != '\t') or byte == 0x7f) {
            index += 1;
            continue;
        }
        try output.append(allocator, byte);
        index += 1;
    }
    return try output.toOwnedSlice(allocator);
}

pub fn run(init: std.process.Init, dialog: *const Dialog) !Outcome {
    const allocator = init.arena.allocator();
    var current = dialog.*;
    if (current.kind == .textbox) {
        current.text = try std.Io.Dir.cwd().readFileAlloc(
            init.io,
            current.text,
            allocator,
            .limited(16 * 1024 * 1024),
        );
    }
    var deck: ?deck_mod.Deck = null;
    if (current.kind == .presentation) {
        const source = try std.Io.Dir.cwd().readFileAlloc(init.io, current.text, allocator, .limited(4 * 1024 * 1024));
        deck = try deck_mod.parse(allocator, source);
        if (deck) |*loaded| {
            for (loaded.screens) |*screen| {
                screen.body = try sanitizeTerminalText(allocator, screen.bodyText(init.environ_map));
                screen.body_env = null;
            }
        }
    }

    var state: State = .{
        .checks = try allocator.alloc(bool, current.items.len),
        .form_fields = try allocator.alloc(FormState, current.fields.len),
        .presentation_screen = if (deck) |loaded| loaded.initialScreen(init.environ_map) else 0,
        .transition_frame = 5,
        .yes_selected = !current.default_no,
        .gauge_percent = current.initial_percent,
        .gauge_text = current.text,
    };
    for (current.items, 0..) |item, i| state.checks[i] = item.checked;
    for (current.fields, 0..) |field, i| {
        state.form_fields[i] = .{};
        try state.form_fields[i].value.appendSlice(allocator, field.initial);
        state.form_fields[i].cursor = state.form_fields[i].value.items.len;
    }
    if (current.default_item) |default_item| {
        for (current.items, 0..) |item, i| {
            if (std.mem.eql(u8, item.tag, default_item)) state.selected = i;
        }
    } else {
        for (state.checks, 0..) |checked, i| {
            if (checked and current.kind == .radiolist) {
                state.selected = i;
                break;
            }
        }
    }
    try state.input.appendSlice(allocator, current.initial_input);
    state.input_cursor = state.input.items.len;

    var tty_buffer: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(init.io, &tty_buffer);
    defer tty.deinit();

    var vx = try vaxis.init(init.io, init.gpa, init.environ_map, .{});
    defer vx.deinit(init.gpa, tty.writer());

    var loop: vaxis.Loop(Event) = .init(init.io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    const palette = presentation.Palette.init(&vx, current.theme);
    current.animate = current.animate and palette.theme != .classic and !palette.monochrome;
    if (deck != null and current.animate) state.transition_frame = 0;
    switch (try loop.nextEvent()) {
        .winsize => |size| try vx.resize(init.gpa, tty.writer(), size),
        .key_press => |key| try handleKey(&current, &state, key, allocator, deck, init.environ_map),
        .gauge_update => |update| {
            if (update.percent) |percent| state.gauge_percent = @min(percent, 100);
            if (update.text) |text| state.gauge_text = text;
        },
        .gauge_done => state.result = .accepted,
        .tick, .focus_in => {},
        .mouse => |mouse| handleMouse(&vx, &current, &state, mouse, deck, init.environ_map),
    }
    const layout = computeLayout(&vx, &current);
    if (layout.modern and !current.no_mouse) {
        try vx.setMouseMode(tty.writer(), true);
        vx.setMouseShape(.pointer);
    }

    var image: ?vaxis.Image = null;
    if (current.image_path) |path| {
        if (vx.caps.kitty_graphics) image = try transmitImagePath(&vx, init.io, init.gpa, tty.writer(), path);
    }
    defer {
        if (image) |loaded| vx.freeImage(tty.writer(), loaded.id);
    }

    var ticker: ?std.Io.Future(void) = null;
    if (current.animate) ticker = try init.io.concurrent(tickLoop, .{ init.io, &loop });
    defer {
        if (ticker) |*thread| thread.cancel(init.io);
    }

    var gauge_reader: ?std.Io.Future(void) = null;
    if (current.kind == .gauge) gauge_reader = try init.io.concurrent(gaugeReadLoop, .{ init.io, &loop, allocator });
    defer {
        if (gauge_reader) |*thread| thread.cancel(init.io);
    }

    const splash_frames: usize = if (current.animate) 5 else 1;
    var frame: usize = 0;
    for (0..splash_frames) |_| {
        try draw(&vx, &current, &state, frame, image, deck, init.environ_map);
        try vx.render(tty.writer());
        frame +%= 1;
        if (current.animate) try init.io.sleep(.fromMilliseconds(32), .awake);
    }
    if (current.kind == .infobox) state.result = .accepted;

    while (state.result == null) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| try handleKey(&current, &state, key, allocator, deck, init.environ_map),
            .winsize => |size| try vx.resize(init.gpa, tty.writer(), size),
            .gauge_update => |update| {
                if (update.percent) |percent| state.gauge_percent = @min(percent, 100);
                if (update.text) |text| state.gauge_text = text;
            },
            .gauge_done => state.result = .accepted,
            .mouse => |mouse| handleMouse(&vx, &current, &state, mouse, deck, init.environ_map),
            .tick => {
                if (current.kind == .presentation and state.transition_frame < 5) state.transition_frame += 1;
            },
            .focus_in => {},
        }
        frame +%= 1;
        try draw(&vx, &current, &state, frame, image, deck, init.environ_map);
        try vx.render(tty.writer());
    }

    if (current.clear_on_exit) {
        try vx.resetState(tty.writer());
        try tty.writer().writeAll("\x1b[2J\x1b[H");
        try tty.writer().flush();
    }

    const form_values = try allocator.alloc([]const u8, state.form_fields.len);
    for (state.form_fields, 0..) |field, i| form_values[i] = field.value.items;
    return .{
        .result = state.result.?,
        .selected = state.selected,
        .checks = state.checks,
        .input = state.input.items,
        .form_values = form_values,
    };
}

fn tickLoop(io: std.Io, loop: *vaxis.Loop(Event)) void {
    while (true) {
        io.sleep(.fromMilliseconds(100), .awake) catch return;
        loop.postEvent(.tick) catch return;
    }
}

fn gaugeReadLoop(io: std.Io, loop: *vaxis.Loop(Event), allocator: std.mem.Allocator) void {
    var line: std.ArrayList(u8) = .empty;
    var message: std.ArrayList(u8) = .empty;
    var reading_message = false;
    var buffer: [1024]u8 = undefined;
    const stdin = std.Io.File.stdin();
    while (true) {
        const count = stdin.readStreaming(io, &.{&buffer}) catch break;
        if (count == 0) break;
        for (buffer[0..count]) |byte| {
            if (byte == '\n') {
                if (!consumeGaugeLine(allocator, loop, &line, &message, &reading_message)) return;
            } else {
                line.append(allocator, byte) catch return;
            }
        }
    }
    if (line.items.len > 0 and !consumeGaugeLine(allocator, loop, &line, &message, &reading_message)) return;
    loop.postEvent(.gauge_done) catch {};
}

fn consumeGaugeLine(
    allocator: std.mem.Allocator,
    loop: *vaxis.Loop(Event),
    line: *std.ArrayList(u8),
    message: *std.ArrayList(u8),
    reading_message: *bool,
) bool {
    const value = std.mem.trim(u8, line.items, " \t\r");
    defer line.clearRetainingCapacity();
    if (std.mem.eql(u8, value, "XXX")) {
        if (reading_message.*) {
            const text = allocator.dupe(u8, message.items) catch return false;
            loop.postEvent(.{ .gauge_update = .{ .text = text } }) catch return false;
            message.clearRetainingCapacity();
        }
        reading_message.* = !reading_message.*;
        return true;
    }
    if (reading_message.*) {
        if (message.items.len > 0) message.append(allocator, '\n') catch return false;
        message.appendSlice(allocator, value) catch return false;
        return true;
    }
    const percent = std.fmt.parseUnsigned(u8, value, 10) catch return true;
    loop.postEvent(.{ .gauge_update = .{ .percent = @min(percent, 100) } }) catch return false;
    return true;
}


fn handleKey(dialog: *const Dialog, state: *State, key: vaxis.Key, allocator: std.mem.Allocator, deck: ?deck_mod.Deck, env: *std.process.Environ.Map) !void {
    if (key.matches('c', .{ .ctrl = true })) {
        state.result = .escaped;
        return;
    }
    if (key.matches(vaxis.Key.escape, .{})) {
        if (!dialog.no_cancel) state.result = .escaped;
        return;
    }

    const scrollable_text = dialog.kind == .textbox or (dialog.scroll_text and (dialog.kind == .message or dialog.kind == .yesno));
    if (scrollable_text) {
        const visible_rows: usize = @max(@as(usize, 1), @as(usize, dialog.height.?) -| 4);
        const max_scroll = maxTextScroll(dialog.text, visible_rows);
        if (key.matchesAny(&.{ vaxis.Key.up, 'k' }, .{})) {
            state.scroll_offset -|= 1;
            return;
        } else if (key.matchesAny(&.{ vaxis.Key.down, 'j' }, .{})) {
            state.scroll_offset = @min(max_scroll, state.scroll_offset + 1);
            return;
        } else if (key.matches(vaxis.Key.page_up, .{})) {
            state.scroll_offset -|= visible_rows;
            return;
        } else if (key.matches(vaxis.Key.page_down, .{})) {
            state.scroll_offset = @min(max_scroll, state.scroll_offset + visible_rows);
            return;
        } else if (key.matches(vaxis.Key.home, .{})) {
            state.scroll_offset = 0;
            return;
        } else if (key.matches(vaxis.Key.end, .{})) {
            state.scroll_offset = max_scroll;
            return;
        }
        if (dialog.kind == .textbox) {
            if (key.matches(vaxis.Key.enter, .{})) state.result = .accepted;
            return;
        }
    }

    if (dialog.kind == .yesno) {
        if (key.matchesAny(&.{ vaxis.Key.left, vaxis.Key.right, vaxis.Key.tab }, .{})) {
            state.yes_selected = !state.yes_selected;
        } else if (key.matches('y', .{})) {
            state.result = .accepted;
        } else if (key.matches('n', .{})) {
            state.result = .cancelled;
        } else if (key.matches(vaxis.Key.enter, .{})) {
            state.result = if (state.yes_selected) .accepted else .cancelled;
        } else if (key.matches('q', .{}) and !dialog.no_cancel) {
            state.result = .cancelled;
        }
        return;
    }

    if (dialog.kind == .gauge) return;

    if (dialog.kind == .presentation) {
        const loaded = deck orelse {
            state.result = .accepted;
            return;
        };
        if (key.matchesAny(&.{ vaxis.Key.right, vaxis.Key.page_down, vaxis.Key.enter, ' ' }, .{})) {
            if (loaded.next(state.presentation_screen, env)) |next| {
                state.presentation_screen = next;
                state.transition_frame = 0;
                state.transition_direction = 1;
            } else state.result = .accepted;
        } else if (key.matchesAny(&.{ vaxis.Key.left, vaxis.Key.page_up, vaxis.Key.backspace }, .{})) {
            if (loaded.previous(state.presentation_screen)) |previous| {
                state.presentation_screen = previous;
                state.transition_frame = 0;
                state.transition_direction = -1;
            }
        } else if (key.matches(vaxis.Key.home, .{})) {
            state.presentation_screen = loaded.start;
            state.transition_frame = 0;
            state.transition_direction = -1;
        }
        return;
    }

    if (key.matches(vaxis.Key.enter, .{})) {
        if (dialog.kind == .radiolist) {
            @memset(state.checks, false);
            state.checks[state.selected] = true;
        }
        state.result = .accepted;
        return;
    }
    if (key.matches(' ', .{}) and (dialog.kind == .checklist or dialog.kind == .radiolist)) {
        if (dialog.kind == .checklist) {
            state.checks[state.selected] = !state.checks[state.selected];
        } else {
            @memset(state.checks, false);
            state.checks[state.selected] = true;
        }
        return;
    }
    if (dialog.kind == .form) {
        if (key.matches(vaxis.Key.tab, .{}) or key.matches(vaxis.Key.tab, .{ .shift = true })) {
            state.active_field = if (key.mods.shift)
                (state.active_field + state.form_fields.len - 1) % state.form_fields.len
            else
                (state.active_field + 1) % state.form_fields.len;
        } else if (key.matches(vaxis.Key.up, .{})) {
            state.active_field = if (state.active_field == 0) state.form_fields.len - 1 else state.active_field - 1;
        } else if (key.matches(vaxis.Key.down, .{})) {
            state.active_field = (state.active_field + 1) % state.form_fields.len;
        } else {
            const field = &state.form_fields[state.active_field];
            try editText(&field.value, &field.cursor, key, allocator);
        }
        return;
    }



    if (dialog.kind == .menu or dialog.kind == .checklist or dialog.kind == .radiolist) {
        if (key.matchesAny(&.{ vaxis.Key.up, 'k' }, .{})) {
            state.selected -|= 1;
        } else if (key.matchesAny(&.{ vaxis.Key.down, 'j' }, .{})) {
            state.selected = @min(dialog.items.len - 1, state.selected + 1);
        } else if (key.matches(vaxis.Key.home, .{})) {
            state.selected = 0;
        } else if (key.matches(vaxis.Key.end, .{})) {
            state.selected = dialog.items.len - 1;
        } else if (key.matches(vaxis.Key.page_up, .{})) {
            state.selected -|= 8;
        } else if (key.matches(vaxis.Key.page_down, .{})) {
            state.selected = @min(dialog.items.len - 1, state.selected + 8);
        }
        return;
    }


    if (dialog.kind == .input or dialog.kind == .password) {
        try editText(&state.input, &state.input_cursor, key, allocator);
    }
}

fn editText(buffer: *std.ArrayList(u8), cursor: *usize, key: vaxis.Key, allocator: std.mem.Allocator) !void {
    if (key.matches(vaxis.Key.left, .{})) {
        cursor.* = previousCodepoint(buffer.items, cursor.*);
    } else if (key.matches(vaxis.Key.right, .{})) {
        cursor.* = nextCodepoint(buffer.items, cursor.*);
    } else if (key.matches(vaxis.Key.home, .{})) {
        cursor.* = 0;
    } else if (key.matches(vaxis.Key.end, .{})) {
        cursor.* = buffer.items.len;
    } else if (key.matches(vaxis.Key.backspace, .{})) {
        if (cursor.* > 0) {
            const previous = previousCodepoint(buffer.items, cursor.*);
            std.mem.copyForwards(u8, buffer.items[previous..], buffer.items[cursor.*..]);
            buffer.items.len -= cursor.* - previous;
            cursor.* = previous;
        }
    } else if (key.matches(vaxis.Key.delete, .{})) {
        if (cursor.* < buffer.items.len) {
            const next = nextCodepoint(buffer.items, cursor.*);
            std.mem.copyForwards(u8, buffer.items[cursor.*..], buffer.items[next..]);
            buffer.items.len -= next - cursor.*;
        }
    } else if (key.matches('u', .{ .ctrl = true })) {
        buffer.clearRetainingCapacity();
        cursor.* = 0;
    } else if (!key.mods.ctrl and !key.mods.alt) {
        var encoded: [4]u8 = undefined;
        const text = if (key.text) |text| text else blk: {
            if (key.codepoint < 0x20 or key.codepoint == 0x7f) return;
            const length = std.unicode.utf8Encode(key.codepoint, &encoded) catch return;
            break :blk encoded[0..length];
        };
        try buffer.insertSlice(allocator, cursor.*, text);
        cursor.* += text.len;
    }
}

fn previousCodepoint(text: []const u8, cursor: usize) usize {
    if (cursor == 0) return 0;
    var index = cursor - 1;
    while (index > 0 and text[index] & 0xc0 == 0x80) index -= 1;
    return index;
}

fn nextCodepoint(text: []const u8, cursor: usize) usize {
    if (cursor >= text.len) return text.len;
    var index = cursor + 1;
    while (index < text.len and text[index] & 0xc0 == 0x80) index += 1;
    return index;
}

fn draw(vx: *vaxis.Vaxis, dialog: *const Dialog, state: *State, frame: usize, image: ?vaxis.Image, deck: ?deck_mod.Deck, env: *std.process.Environ.Map) !void {
    const root = vx.window();
    root.clear();
    root.hideCursor();
    if (root.width == 0 or root.height == 0) return;

    const palette = presentation.Palette.init(vx, dialog.theme);
    const glyphs = presentation.resolveGlyphs(vx, dialog.glyphs);
    const layout = computeLayout(vx, dialog);
    const screen = if (dialog.kind == .presentation) deck.?.screens[state.presentation_screen] else null;
    const title = if (screen) |slide| slide.title else dialog.title;
    if (layout.modern) {
        root.fill(.{ .style = .{ .fg = palette.foreground, .bg = palette.app_background } });
        drawModernChrome(root, vx, dialog, state, layout, palette, glyphs, frame, deck);
    } else if (dialog.backtitle) |backtitle| {
        _ = root.printSegment(.{ .text = backtitle, .style = .{ .fg = palette.muted } }, .{ .col_offset = 2, .row_offset = 0, .wrap = .none });
    }

    const panel = root.child(.{
        .x_off = layout.panel_x,
        .y_off = layout.panel_y,
        .width = layout.panel_width,
        .height = layout.panel_height,
        .border = .{ .where = .all, .style = .{ .fg = palette.border, .bold = true }, .glyphs = presentation.borderGlyphs(glyphs) },
    });
    panel.fill(.{ .style = .{ .fg = palette.foreground, .bg = palette.panel_background } });
    _ = root.print(&.{
        .{ .text = " ", .style = .{} },
        .{ .text = presentation.logo(glyphs), .style = .{ .fg = palette.accent, .bold = true } },
        .{ .text = " ", .style = .{} },
        .{ .text = title, .style = .{ .fg = palette.foreground, .bold = true } },
    }, .{ .col_offset = @intCast(@max(layout.panel_x + 2, 0)), .row_offset = @intCast(@max(layout.panel_y, 0)), .wrap = .none });
    if (dialog.animate and !palette.monochrome and layout.panel_width > 8) {
        _ = root.printSegment(.{ .text = presentation.spinner(glyphs, frame), .style = .{ .fg = palette.accent } }, .{ .col_offset = @intCast(@max(layout.panel_x + @as(i17, @intCast(layout.panel_width)) - 3, 0)), .row_offset = @intCast(@max(layout.panel_y, 0)), .wrap = .none });
    }

    const content = root.child(.{ .x_off = layout.panel_x + 1, .y_off = layout.panel_y + 1, .width = layout.panel_width -| 2, .height = layout.panel_height -| 2 });
    if (layout.modern) {
        _ = content.print(&.{
            .{ .text = "ACTIVE VIEW  /  ", .style = .{ .fg = palette.muted, .bold = true } },
            .{ .text = modeName(dialog.kind), .style = .{ .fg = palette.accent, .bold = true } },
        }, .{ .col_offset = 2, .row_offset = 0, .wrap = .none });
    } else {
        const separator = if (glyphs == .ascii) " - " else " · ";
        const tagline = if (palette.theme == .classic) "whiptail-style terminal dialogs" else "terminal dialogs, with a little motion";
        _ = content.print(&.{
            .{ .text = presentation.logo(glyphs), .style = .{ .fg = palette.accent, .bold = true } },
            .{ .text = "  ziptail", .style = .{ .fg = palette.accent, .bold = true } },
            .{ .text = separator, .style = .{ .fg = palette.muted, .dim = true } },
            .{ .text = tagline, .style = .{ .fg = palette.muted, .dim = true } },
        }, .{ .col_offset = 2, .row_offset = 0, .wrap = .none });
    }

    const show_image = image != null and content.width > 30 and content.height > 3;
    const body_width = if (show_image) content.width -| 17 else content.width;
    const body = content.child(.{ .width = body_width, .height = content.height });
    const footer_row = content.height -| 1;
    const message_row: u16 = if (dialog.kind == .textbox) 1 else @min(2, body.height -| 1);
    const message = if (screen) |slide| slide.bodyText(env) else if (dialog.kind == .gauge) state.gauge_text else dialog.text;
    const message_width = @max(body.width -| 4, 1);
    const list_start: u16 = @min(body.height -| 2, message_row +| estimateRows(message, message_width) +| 1);

    switch (dialog.kind) {
        .textbox => drawTextBox(body, dialog, state, message_row, footer_row, palette, glyphs),
        .gauge => {
            _ = body.printSegment(.{ .text = message, .style = .{ .fg = palette.foreground } }, .{ .col_offset = 2, .row_offset = message_row, .wrap = .word });
            drawGauge(body, state, list_start, footer_row, palette, glyphs);
        },
        .form => {
            _ = body.printSegment(.{ .text = dialog.text, .style = .{ .fg = palette.foreground } }, .{ .col_offset = 2, .row_offset = message_row, .wrap = .word });
            drawForm(body, dialog, state, list_start, footer_row, palette);
        },
        .presentation => drawPresentation(body, screen.?, state, footer_row, palette, glyphs, vx.caps.scaled_text, dialog.animate, env),
        .message, .yesno, .infobox, .input, .password, .menu, .checklist, .radiolist => {
            if (dialog.scroll_text and (dialog.kind == .message or dialog.kind == .yesno)) {
                drawTextBox(body, dialog, state, message_row, footer_row, palette, glyphs);
            } else {
                _ = body.printSegment(.{ .text = dialog.text, .style = .{ .fg = palette.foreground } }, .{ .col_offset = 2, .row_offset = message_row, .wrap = .word });
            }
            switch (dialog.kind) {
                .input, .password => drawInput(body, dialog, state, list_start, footer_row, palette, glyphs),
                .menu, .checklist, .radiolist => drawItems(body, dialog, state, list_start, footer_row, palette, glyphs),
                else => {},
            }
        },
    }
    drawButtons(content, dialog, state, footer_row, palette);

    if (dialog.kind == .textbox and (dialog.scroll_text or lineCount(dialog.text) > footer_row -| message_row)) {
        drawScrollbar(body, dialog.text, state.scroll_offset, message_row, footer_row, palette, glyphs);
    } else if (dialog.scroll_text and (dialog.kind == .message or dialog.kind == .yesno)) {
        drawScrollbar(body, dialog.text, state.scroll_offset, message_row, footer_row, palette, glyphs);
    }

    if (show_image and vx.screen.width > 0 and vx.screen.height > 0) {
        const artwork = content.child(.{ .x_off = @intCast(content.width -| 16), .y_off = 1, .width = 14, .height = @min(6, content.height -| 2) });
        try image.?.draw(artwork, .{ .scale = .contain, .z_index = 1 });
    }
    if (layout.modern) {
        drawModernFooter(root, dialog, state, palette, glyphs, deck);
    } else if (root.height > 1) {
        const hint = if (dialog.kind == .textbox)
            (if (glyphs == .ascii) "Up/Down scroll   Enter close   Esc cancel" else "↑/↓ scroll   PgUp/PgDn page   Enter close   Esc cancel")
        else if (glyphs == .ascii)
            "Enter select   Esc cancel"
        else
            "↑/↓ navigate   Enter select   Esc cancel";
        _ = root.printSegment(.{ .text = hint, .style = .{ .fg = palette.muted, .dim = true } }, .{ .col_offset = 2, .row_offset = root.height - 1, .wrap = .none });
    }
}

fn modeName(kind: @import("dialog.zig").Kind) []const u8 {
    return switch (kind) {
        .message => "MESSAGE",
        .yesno => "CONFIRMATION",
        .infobox => "NOTICE",
        .input => "TEXT INPUT",
        .password => "SECURE INPUT",
        .form => "FORM",
        .menu => "SELECTION",
        .checklist => "MULTI-SELECT",
        .radiolist => "SINGLE-SELECT",
        .textbox => "DOCUMENT",
        .gauge => "PROGRESS",
        .presentation => "PRESENTATION",
    };
}

fn drawModernChrome(root: vaxis.Window, vx: *const vaxis.Vaxis, dialog: *const Dialog, state: *const State, layout: Layout, palette: presentation.Palette, glyphs: presentation.GlyphMode, frame: usize, deck: ?deck_mod.Deck) void {
    const header_title = if (deck) |loaded| loaded.title else dialog.backtitle orelse dialog.title;
    _ = root.print(&.{
        .{ .text = presentation.logo(glyphs), .style = .{ .fg = palette.accent, .bold = true } },
        .{ .text = "  ziptail", .style = .{ .fg = palette.foreground, .bold = true } },
        .{ .text = "  /  ", .style = .{ .fg = palette.muted } },
        .{ .text = header_title, .style = .{ .fg = palette.muted } },
    }, .{ .col_offset = 2, .row_offset = 0, .wrap = .none });

    const renderer = if (vx.caps.kitty_graphics) "KITTY GRAPHICS" else if (vx.caps.rgb) "TRUECOLOR" else "COLOR TERMINAL";
    _ = root.printSegment(.{ .text = renderer, .style = .{ .fg = palette.accent, .bold = true } }, .{ .col_offset = root.width -| @as(u16, @intCast(@min(renderer.len + 2, root.width))), .row_offset = 0, .wrap = .none });
    _ = root.printSegment(.{ .text = presentation.spinner(glyphs, frame), .style = .{ .fg = palette.accent } }, .{ .col_offset = 2, .row_offset = 1, .wrap = .none });
    const subtitle = if (glyphs == .ascii) "INTERACTIVE - RESIZABLE - TTY RESTORE ENABLED" else "INTERACTIVE  ·  RESIZABLE  ·  TTY RESTORE ENABLED";
    _ = root.printSegment(.{ .text = subtitle, .style = .{ .fg = palette.muted, .dim = true } }, .{ .col_offset = 5, .row_offset = 1, .wrap = .none });
    drawHorizontalRule(root, 2, 2, root.width -| 4, palette, glyphs);
    if (layout.sidebar_width > 0) drawSidebar(root, vx, dialog, state, layout, palette, glyphs, deck);
}

fn drawSidebar(root: vaxis.Window, vx: *const vaxis.Vaxis, dialog: *const Dialog, state: *const State, layout: Layout, palette: presentation.Palette, glyphs: presentation.GlyphMode, deck: ?deck_mod.Deck) void {
    const left = root.child(.{ .x_off = 1, .y_off = 3, .width = layout.sidebar_width -| 1, .height = root.height -| 6 });
    const section_style: vaxis.Style = .{ .fg = palette.muted, .bold = true };
    _ = left.printSegment(.{ .text = "SESSION", .style = section_style }, .{ .col_offset = 1, .row_offset = 1, .wrap = .none });
    _ = left.print(&.{
        .{ .text = if (glyphs == .ascii) "* " else "● ", .style = .{ .fg = palette.accent } },
        .{ .text = modeName(dialog.kind), .style = .{ .fg = palette.foreground, .bold = true } },
    }, .{ .col_offset = 1, .row_offset = 3, .wrap = .none });
    _ = left.printSegment(.{ .text = "RENDERER", .style = section_style }, .{ .col_offset = 1, .row_offset = 6, .wrap = .none });
    const color_mode = if (palette.monochrome) "MONOCHROME" else if (vx.caps.rgb) "TRUECOLOR" else "INDEXED COLOR";
    _ = left.printSegment(.{ .text = color_mode, .style = .{ .fg = palette.accent } }, .{ .col_offset = 1, .row_offset = 7, .wrap = .none });
    const glyph_mode = switch (glyphs) {
        .ascii => "ASCII GLYPHS",
        .nerd => "NERD GLYPHS",
        .rounded, .square => "UNICODE GLYPHS",
    };
    _ = left.printSegment(.{ .text = glyph_mode, .style = .{ .fg = palette.muted } }, .{ .col_offset = 1, .row_offset = 8, .wrap = .none });
    _ = left.printSegment(.{ .text = if (vx.caps.kitty_graphics) "IMAGE PROTOCOL READY" else "TEXT FALLBACK READY", .style = .{ .fg = palette.muted } }, .{ .col_offset = 1, .row_offset = 10, .wrap = .none });
    if (deck) |loaded| {
        var step_buf: [24]u8 = undefined;
        const step = std.fmt.bufPrint(&step_buf, "SCREEN {d} / {d}", .{ state.presentation_screen + 1, loaded.screens.len }) catch unreachable;
        _ = left.printSegment(.{ .text = step, .style = .{ .fg = palette.accent, .bold = true } }, .{ .col_offset = 1, .row_offset = 12, .wrap = .none });
    } else if (dialog.kind == .form) {
        var count_buf: [16]u8 = undefined;
        const count = std.fmt.bufPrint(&count_buf, "{d} FIELDS", .{dialog.fields.len}) catch unreachable;
        _ = left.printSegment(.{ .text = count, .style = .{ .fg = palette.accent } }, .{ .col_offset = 1, .row_offset = 12, .wrap = .none });
    } else if (dialog.kind == .gauge) {
        var progress_buf: [8]u8 = undefined;
        const progress = std.fmt.bufPrint(&progress_buf, "{d}%", .{state.gauge_percent}) catch unreachable;
        _ = left.printSegment(.{ .text = progress, .style = .{ .fg = palette.accent, .bold = true } }, .{ .col_offset = 1, .row_offset = 12, .wrap = .none });
    }

    const divider = if (glyphs == .ascii) "|" else "│";
    const divider_col = @as(u16, @intCast(@max(@as(i17, 0), layout.panel_x - 2)));
    var row: u16 = 3;
    while (row < root.height -| 3) : (row += 1) {
        root.writeCell(divider_col, row, .{ .char = .{ .grapheme = divider, .width = 1 }, .style = .{ .fg = palette.border, .dim = true } });
    }
}

fn drawModernFooter(root: vaxis.Window, dialog: *const Dialog, state: *const State, palette: presentation.Palette, glyphs: presentation.GlyphMode, deck: ?deck_mod.Deck) void {
    if (root.height < 3) return;
    var status_buffer: [32]u8 = undefined;
    const status: []const u8 = if (dialog.kind == .gauge)
        std.fmt.bufPrint(&status_buffer, "RUNNING  {d}%", .{state.gauge_percent}) catch "RUNNING"
    else if (deck) |loaded|
        std.fmt.bufPrint(&status_buffer, "SCREEN {d} / {d}", .{ state.presentation_screen + 1, loaded.screens.len }) catch "PRESENTATION"
    else
        "READY";
    _ = root.printSegment(.{ .text = status, .style = .{ .fg = palette.accent, .bold = true } }, .{ .col_offset = 2, .row_offset = root.height - 2, .wrap = .none });
    const hints = if (dialog.kind == .form)
        "Tab next field   Enter submit   Esc cancel"
    else if (deck != null)
        (if (glyphs == .ascii) "Left Back   Right Next   Esc Exit" else "← Back   → Continue   Esc Exit")
    else
        "Enter continue   Esc cancel   Mouse: select";
    _ = root.printSegment(.{ .text = hints, .style = .{ .fg = palette.muted } }, .{ .col_offset = 2, .row_offset = root.height - 1, .wrap = .none });
}

fn drawHorizontalRule(win: vaxis.Window, row: u16, start: u16, width: u16, palette: presentation.Palette, glyphs: presentation.GlyphMode) void {
    const line = if (glyphs == .ascii) "-" else "─";
    for (start..@min(win.width, start +| width)) |col| {
        win.writeCell(@intCast(col), row, .{ .char = .{ .grapheme = line, .width = 1 }, .style = .{ .fg = palette.border, .dim = true } });
    }
}

fn formListStart(dialog: *const Dialog, width: u16, height: u16) u16 {
    const message_row: u16 = @min(2, height -| 1);
    return @min(height -| 2, message_row +| estimateRows(dialog.text, @max(width -| 4, 1)) +| 1);
}


fn advanceDeck(deck: deck_mod.Deck, state: *State, env: *std.process.Environ.Map, forward: bool) bool {
    const target = (if (forward) deck.next(state.presentation_screen, env) else deck.previous(state.presentation_screen)) orelse return false;
    state.presentation_screen = target;
    state.transition_frame = 0;
    state.transition_direction = if (forward) 1 else -1;
    return true;
}

fn drawForm(content: vaxis.Window, dialog: *const Dialog, state: *State, first_row: u16, footer_row: u16, palette: presentation.Palette) void {
    if (first_row >= footer_row or dialog.fields.len == 0) return;
    const visible = @min(dialog.fields.len, (footer_row - first_row) / 2);
    const start = if (state.active_field >= visible) state.active_field - visible + 1 else 0;
    for (0..visible) |offset| {
        const index = start + offset;
        const screen = dialog.fields[index];
        const value = &state.form_fields[index];
        const label_row = first_row + @as(u16, @intCast(offset * 2));
        const focused = index == state.active_field;
        _ = content.printSegment(.{ .text = screen.label, .style = .{ .fg = if (focused) palette.accent else palette.muted, .bold = focused } }, .{ .col_offset = 2, .row_offset = label_row, .wrap = .none });
        const input = content.child(.{ .x_off = 2, .y_off = @intCast(label_row +| 1), .width = @max(content.width -| 4, 1), .height = 1 });
        input.fill(.{ .style = .{ .fg = palette.foreground, .bg = palette.field_background } });
        _ = input.printSegment(.{ .text = value.value.items, .style = .{ .fg = palette.foreground, .bg = palette.field_background, .bold = focused, .reverse = focused and palette.monochrome } }, .{ .col_offset = 1, .row_offset = 0, .wrap = .none });
        if (focused) {
            const cursor = input.gwidth(value.value.items[0..@min(value.cursor, value.value.items.len)]);
            input.showCursor(@min(cursor +| 1, input.width -| 1), 0);
        }
    }
}

fn drawPresentation(content: vaxis.Window, screen: deck_mod.Screen, state: *State, footer_row: u16, palette: presentation.Palette, glyphs: presentation.GlyphMode, scaled_text: bool, animated: bool, env: *std.process.Environ.Map) void {
    const progress = if (animated) @min(state.transition_frame, 5) else 5;
    const remaining: i17 = @intCast(5 - progress);
    var slide_x: i17 = 0;
    if (animated and screen.transition == .slide_left) slide_x = if (state.transition_direction < 0) -remaining * 3 else remaining * 3;
    if (animated and screen.transition == .slide_right) slide_x = if (state.transition_direction < 0) remaining * 3 else -remaining * 3;
    const surface = content.child(.{ .x_off = slide_x, .y_off = 0, .width = content.width, .height = content.height });
    const faded = animated and screen.transition == .fade and progress < 4;
    const heading_style: vaxis.Style = .{ .fg = if (faded) palette.muted else palette.accent, .bold = true, .dim = faded };
    const heading_row: u16 = 2;
    if (screen.scale == .large) {
        drawLargeTitle(surface, screen.title, heading_row, heading_style, scaled_text);
    } else {
        _ = surface.printSegment(.{ .text = screen.title, .style = heading_style }, .{ .col_offset = 2, .row_offset = heading_row, .wrap = .none });
    }
    const body_row: u16 = if (screen.scale == .large) 6 else 4;
    const body = screen.bodyText(env);
    if (body_row < footer_row) {
        _ = surface.printSegment(.{ .text = body, .style = .{ .fg = if (faded) palette.muted else palette.foreground, .dim = faded } }, .{ .col_offset = 2, .row_offset = body_row, .wrap = .word });
    }
    if (screen.scale == .large and !scaled_text) {
        drawHorizontalRule(surface, body_row -| 1, 2, surface.width -| 4, palette, glyphs);
    }
}

fn drawLargeTitle(win: vaxis.Window, text: []const u8, row: u16, style: vaxis.Style, scaled_text: bool) void {
    if (!scaled_text) {
        _ = win.printSegment(.{ .text = text, .style = style }, .{ .col_offset = 2, .row_offset = row, .wrap = .word });
        return;
    }
    var col: u16 = 2;
    var iterator = vaxis.unicode.graphemeIterator(text);
    while (iterator.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const width = @max(win.gwidth(bytes), 1);
        win.writeCell(col, row, .{
            .char = .{ .grapheme = bytes, .width = @intCast(width) },
            .style = style,
            .scale = .{ .scale = 2 },
        });
        col +|= width * 2;
    }
}

fn handleMouse(vx: *vaxis.Vaxis, dialog: *const Dialog, state: *State, mouse: vaxis.Mouse, deck: ?deck_mod.Deck, env: *std.process.Environ.Map) void {
    const layout = computeLayout(vx, dialog);
    if (!layout.modern or dialog.no_mouse) return;
    if (mouse.col < 0 or mouse.row < 0) return;
    const column: u16 = @intCast(mouse.col);
    const row: u16 = @intCast(mouse.row);
    if (mouse.button == .wheel_up or mouse.button == .wheel_down) {
        if (dialog.kind == .presentation) {
            if (deck) |loaded| _ = advanceDeck(loaded, state, env, mouse.button == .wheel_down);
        } else if (dialog.kind == .textbox or dialog.scroll_text) {
            if (mouse.button == .wheel_up) state.scroll_offset -|= 1 else state.scroll_offset += 1;
        } else if (dialog.items.len > 0) {
            if (mouse.button == .wheel_up) state.selected -|= 1 else state.selected = @min(dialog.items.len - 1, state.selected + 1);
        }
        return;
    }
    if (mouse.button != .left or mouse.type != .press) return;

    const panel_left: u16 = @intCast(layout.panel_x);
    const panel_top: u16 = @intCast(layout.panel_y);
    const content_width = layout.panel_width -| 2;
    const content_height = layout.panel_height -| 2;
    const content_left = panel_left + 1;
    const content_top = panel_top + 1;
    const button_row = panel_top + layout.panel_height -| 2;
    if (row == button_row and column >= content_left and column < content_left + content_width) {
        if (dialog.kind == .yesno) {
            state.yes_selected = column < content_left + content_width / 2;
            state.result = if (state.yes_selected) .accepted else .cancelled;
        } else if (dialog.kind == .presentation) {
            if (deck) |loaded| {
                if (!advanceDeck(loaded, state, env, column >= content_left + content_width / 2)) state.result = .accepted;
            }
        } else {
            state.result = .accepted;
        }
        return;
    }

    if (dialog.kind == .form) {
        const start = formListStart(dialog, content_width, content_height);
        if (row >= content_top + start) {
            const index = @as(usize, @intCast((row - (content_top + start)) / 2));
            if (index < dialog.fields.len) state.active_field = index;
        }
        return;
    }
    if (dialog.kind != .menu and dialog.kind != .checklist and dialog.kind != .radiolist) return;

    const body_width = if (dialog.image_path != null and vx.caps.kitty_graphics and content_width > 30) content_width -| 17 else content_width;
    const message_row: u16 = @min(2, content_height -| 1);
    const message_width = @max(body_width -| 4, 1);
    const list_start = @min(content_height -| 2, message_row +| estimateRows(dialog.text, message_width) +| 1);
    const footer = content_height -| 1;
    if (row < content_top + list_start or row >= content_top + footer) return;
    const available = footer - list_start;
    const visible: usize = @min(dialog.items.len, available);
    const start = if (state.selected >= visible) state.selected - visible + 1 else 0;
    const selected = start + @as(usize, @intCast(row - (content_top + list_start)));
    if (selected >= dialog.items.len) return;
    state.selected = selected;
    if (dialog.kind == .checklist) {
        state.checks[selected] = !state.checks[selected];
    } else if (dialog.kind == .radiolist) {
        @memset(state.checks, false);
        state.checks[selected] = true;
    }
}

fn drawInput(content: vaxis.Window, dialog: *const Dialog, state: *State, row: u16, footer_row: u16, palette: presentation.Palette, glyphs: presentation.GlyphMode) void {
    if (row >= footer_row) return;
    const field = content.child(.{
        .x_off = 2,
        .y_off = @intCast(row),
        .width = @max(content.width -| 4, 1),
        .height = 1,
    });
    const field_style: vaxis.Style = .{ .fg = palette.foreground, .bg = palette.field_background };
    field.fill(.{ .style = field_style });

    var display: []const u8 = state.input.items;
    var display_cursor = state.input_cursor;
    var masked: [2048]u8 = undefined;
    if (dialog.kind == .password) {
        const mask = switch (glyphs) {
            .ascii => "*",
            .nerd => "\u{f023}",
            else => "●",
        };
        var source_index: usize = 0;
        var masked_len: usize = 0;
        display_cursor = 0;
        while (source_index < state.input.items.len and masked_len + mask.len <= masked.len) {
            if (source_index < state.input_cursor) display_cursor += mask.len;
            source_index = nextCodepoint(state.input.items, source_index);
            @memcpy(masked[masked_len .. masked_len + mask.len], mask);
            masked_len += mask.len;
        }
        display = masked[0..masked_len];
    }
    const prompt = if (glyphs == .ascii) "> " else "› ";
    _ = field.print(&.{
        .{ .text = prompt, .style = .{ .fg = palette.accent, .bold = true } },
        .{ .text = display, .style = field_style },
    }, .{ .row_offset = 0, .wrap = .none });
    const safe_cursor = @min(display_cursor, display.len);
    const cursor_cells = field.gwidth(display[0..safe_cursor]);
    field.showCursor(@min(cursor_cells +| 2, field.width -| 1), 0);
}

fn drawItems(content: vaxis.Window, dialog: *const Dialog, state: *State, row: u16, footer_row: u16, palette: presentation.Palette, glyphs: presentation.GlyphMode) void {
    if (row >= footer_row) return;
    const available = footer_row - row;
    if (available == 0) return;
    const visible: usize = @min(dialog.items.len, available);
    const start = if (state.selected >= visible) state.selected - visible + 1 else 0;
    for (0..visible) |offset| {
        const item_index = start + offset;
        const item = dialog.items[item_index];
        const selected = item_index == state.selected;
        const style: vaxis.Style = if (selected)
            .{ .fg = palette.selected_foreground, .bg = palette.selected_background, .bold = true, .reverse = palette.monochrome }
        else
            .{ .fg = palette.foreground };
        const marker: []const u8 = switch (dialog.kind) {
            .menu => presentation.menuMarker(glyphs, selected),
            .checklist => presentation.checkMarker(glyphs, state.checks[item_index]),
            .radiolist => presentation.radioMarker(glyphs, state.checks[item_index]),
            else => "  ",
        };
        var segments: [4]vaxis.Segment = undefined;
        var count: usize = 0;
        segments[count] = .{ .text = marker, .style = style };
        count += 1;
        if (!dialog.no_tags) {
            segments[count] = .{ .text = item.tag, .style = style };
            count += 1;
        }
        if (!dialog.no_items) {
            if (!dialog.no_tags) {
                segments[count] = .{ .text = "  ", .style = style };
                count += 1;
            }
            segments[count] = .{ .text = item.description, .style = style };
            count += 1;
        }
        _ = content.print(segments[0..count], .{ .col_offset = 2, .row_offset = row + @as(u16, @intCast(offset)), .wrap = .none });
    }
}

fn drawButtons(content: vaxis.Window, dialog: *const Dialog, state: *State, row: u16, palette: presentation.Palette) void {
    if (content.width < 4 or row >= content.height or dialog.kind == .infobox or dialog.kind == .gauge) return;
    const active_style: vaxis.Style = .{
        .fg = palette.selected_foreground,
        .bg = palette.selected_background,
        .bold = true,
        .reverse = palette.monochrome,
    };
    const inactive_style: vaxis.Style = .{ .fg = palette.muted, .reverse = palette.monochrome };
    if (dialog.full_buttons) {
        if (dialog.kind == .yesno) {
            _ = content.printSegment(.{ .text = dialog.yes_button, .style = if (state.yes_selected) active_style else inactive_style }, .{ .col_offset = 2, .row_offset = row, .wrap = .none });
            _ = content.printSegment(.{ .text = dialog.no_button, .style = if (!state.yes_selected) active_style else inactive_style }, .{ .col_offset = content.width -| @as(u16, @intCast(@min(dialog.no_button.len, content.width))), .row_offset = row, .wrap = .none });
        } else {
            _ = content.printSegment(.{ .text = dialog.ok_button, .style = active_style }, .{ .col_offset = 2, .row_offset = row, .wrap = .none });
            if (!dialog.no_cancel) _ = content.printSegment(.{ .text = dialog.cancel_button, .style = inactive_style }, .{ .col_offset = content.width -| @as(u16, @intCast(@min(dialog.cancel_button.len, content.width))), .row_offset = row, .wrap = .none });
        }
        return;
    }

    var segments: [3]vaxis.Segment = undefined;
    var length: usize = 0;
    switch (dialog.kind) {
        .yesno => {
            segments[0] = .{ .text = dialog.yes_button, .style = if (state.yes_selected) active_style else inactive_style };
            segments[1] = .{ .text = "     ", .style = .{} };
            segments[2] = .{ .text = dialog.no_button, .style = if (!state.yes_selected) active_style else inactive_style };
            length = 3;
        },
        .message, .textbox => {
            segments[0] = .{ .text = dialog.ok_button, .style = active_style };
            length = 1;
        },
        else => {
            segments[0] = .{ .text = dialog.ok_button, .style = active_style };
            if (!dialog.no_cancel) {
                segments[1] = .{ .text = "     ", .style = .{} };
                segments[2] = .{ .text = dialog.cancel_button, .style = inactive_style };
                length = 3;
            } else length = 1;
        },
    }
    var text_width: u16 = 0;
    for (segments[0..length]) |segment| text_width +|= @intCast(@min(segment.text.len, std.math.maxInt(u16)));
    const col = (content.width -| text_width) / 2;
    _ = content.print(segments[0..length], .{ .col_offset = col, .row_offset = row, .wrap = .none });
}

fn estimateRows(text: []const u8, width: u16) u16 {
    const usable: usize = @max(width, 1);
    var rows: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| rows += @max(@as(usize, 1), (line.len + usable - 1) / usable);
    return @intCast(@min(rows, std.math.maxInt(u16)));
}

fn drawTextBox(content: vaxis.Window, dialog: *const Dialog, state: *State, row: u16, footer_row: u16, palette: presentation.Palette, glyphs: presentation.GlyphMode) void {
    if (row >= footer_row) return;
    const visible = footer_row - row;
    var lines = std.mem.splitScalar(u8, dialog.text, '\n');
    var line_index: usize = 0;
    var draw_row: u16 = 0;
    while (lines.next()) |line| : (line_index += 1) {
        if (line_index < state.scroll_offset) continue;
        if (draw_row >= visible) break;
        _ = content.printSegment(.{ .text = line, .style = .{ .fg = palette.foreground } }, .{ .col_offset = 2, .row_offset = row + draw_row, .wrap = .none });
        draw_row += 1;
    }
    _ = glyphs;
}

fn drawScrollbar(content: vaxis.Window, text: []const u8, scroll_offset: usize, row: u16, footer_row: u16, palette: presentation.Palette, glyphs: presentation.GlyphMode) void {
    if (row >= footer_row or content.width < 5) return;
    const track_height = footer_row - row;
    const total_lines = lineCount(text);
    const visible: usize = track_height;
    if (total_lines <= visible or visible == 0) return;
    const thumb_height: usize = @max(1, visible * visible / total_lines);
    const max_scroll = total_lines - visible;
    const thumb_start = scroll_offset * (visible -| thumb_height) / max_scroll;
    const track = if (glyphs == .ascii) "|" else "│";
    const thumb = if (glyphs == .ascii) "#" else "█";
    for (0..visible) |offset| {
        const is_thumb = offset >= thumb_start and offset < thumb_start + thumb_height;
        content.writeCell(content.width -| 2, row + @as(u16, @intCast(offset)), .{
            .char = .{ .grapheme = if (is_thumb) thumb else track, .width = 1 },
            .style = .{ .fg = if (is_thumb) palette.accent else palette.muted },
        });
    }
}

fn drawGauge(content: vaxis.Window, state: *const State, row: u16, footer_row: u16, palette: presentation.Palette, glyphs: presentation.GlyphMode) void {
    if (row >= footer_row or content.width < 10) return;
    const bar_width: u16 = @min(content.width -| 6, 52);
    const filled: u16 = @intCast((@as(usize, bar_width) * state.gauge_percent + 50) / 100);
    for (0..bar_width) |offset| {
        const full = offset < filled;
        content.writeCell(3 + @as(u16, @intCast(offset)), row, .{
            .char = .{ .grapheme = presentation.barGlyph(glyphs, full), .width = 1 },
            .style = .{ .fg = if (full) palette.accent else palette.muted, .bold = full },
        });
    }
    var percent_text: [4]u8 = undefined;
    const label = std.fmt.bufPrint(&percent_text, "{d}%", .{state.gauge_percent}) catch unreachable;
    const percent_row = row +| 1;
    if (percent_row < content.height) {
        _ = content.printSegment(.{ .text = label, .style = .{ .fg = palette.accent, .bold = true } }, .{ .col_offset = 3, .row_offset = percent_row, .wrap = .none });
    }
}

fn lineCount(text: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |_| count += 1;
    return count;
}

fn maxTextScroll(text: []const u8, visible_rows: usize) usize {
    return lineCount(text) -| visible_rows;
}
