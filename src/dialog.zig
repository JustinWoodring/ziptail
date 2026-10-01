const std = @import("std");

pub const Kind = enum {
    message,
    yesno,
    infobox,
    input,
    password,
    form,
    presentation,
    menu,
    checklist,
    radiolist,
    textbox,
    gauge,
};

pub const Theme = enum { auto, classic, aurora, sunset, mono };
pub const Glyphs = enum { auto, rounded, square, nerd, ascii };

pub const Item = struct {
    tag: []const u8,
    description: []const u8,
    checked: bool = false,
};

pub const FormField = struct {
    label: []const u8,
    initial: []const u8,
};

pub const Dialog = struct {
    kind: Kind,
    title: []const u8 = "ziptail",
    backtitle: ?[]const u8 = null,
    text: []const u8,
    initial_input: []const u8 = "",
    default_item: ?[]const u8 = null,
    image_path: ?[]const u8 = null,
    items: []Item = &.{} ,
    fields: []FormField = &.{} ,
    width: ?u16 = null,
    height: ?u16 = null,
    list_height: ?u16 = null,
    output_fd: u16 = 2,
    initial_percent: u8 = 0,
    theme: Theme = .auto,
    glyphs: Glyphs = .auto,
    clear_on_exit: bool = false,
    full_buttons: bool = false,
    no_tags: bool = false,
    no_items: bool = false,
    separate_output: bool = false,
    no_cancel: bool = false,
    default_no: bool = false,
    scroll_text: bool = false,
    top_left: bool = false,
    animate: bool = true,
    no_mouse: bool = false,
    ok_button: []const u8 = "OK",
    cancel_button: []const u8 = "Cancel",
    yes_button: []const u8 = "Yes",
    no_button: []const u8 = "No",
};

pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) !Dialog {
    var dialog: Dialog = .{ .kind = .message, .text = "" };
    var has_dialog = false;
    var positional_start: usize = 0;
    var index: usize = 0;

    while (index < args.len) {
        const arg = args[index];
        if (kindForOption(arg)) |kind| {
            if (has_dialog or index + 1 >= args.len) return error.InvalidArguments;
            dialog.kind = kind;
            dialog.text = args[index + 1];
            positional_start = index + 2;
            has_dialog = true;
            break;
        }

        if (std.mem.eql(u8, arg, "--title")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            dialog.title = args[index];
        } else if (std.mem.eql(u8, arg, "--backtitle")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            dialog.backtitle = args[index];
        } else if (std.mem.eql(u8, arg, "--default-item")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            dialog.default_item = args[index];
        } else if (std.mem.eql(u8, arg, "--output-fd")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            dialog.output_fd = try std.fmt.parseUnsigned(u16, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--image")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            dialog.image_path = args[index];
        } else if (std.mem.eql(u8, arg, "--theme")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            dialog.theme = parseEnum(Theme, args[index]) orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--glyphs")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            dialog.glyphs = parseEnum(Glyphs, args[index]) orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--ok-button")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            dialog.ok_button = args[index];
        } else if (std.mem.eql(u8, arg, "--cancel-button")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            dialog.cancel_button = args[index];
        } else if (std.mem.eql(u8, arg, "--yes-button")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            dialog.yes_button = args[index];
        } else if (std.mem.eql(u8, arg, "--no-button")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            dialog.no_button = args[index];
        } else if (std.mem.eql(u8, arg, "--clear")) {
            dialog.clear_on_exit = true;
        } else if (std.mem.eql(u8, arg, "--defaultno")) {
            dialog.default_no = true;
        } else if (std.mem.eql(u8, arg, "--fb") or std.mem.eql(u8, arg, "--fullbuttons")) {
            dialog.full_buttons = true;
        } else if (std.mem.eql(u8, arg, "--nocancel")) {
            dialog.no_cancel = true;
        } else if (std.mem.eql(u8, arg, "--noitem")) {
            dialog.no_items = true;
        } else if (std.mem.eql(u8, arg, "--notags")) {
            dialog.no_tags = true;
        } else if (std.mem.eql(u8, arg, "--separate-output")) {
            dialog.separate_output = true;
        } else if (std.mem.eql(u8, arg, "--scrolltext")) {
            dialog.scroll_text = true;
        } else if (std.mem.eql(u8, arg, "--topleft")) {
            dialog.top_left = true;
        } else if (std.mem.eql(u8, arg, "--no-animation")) {
            dialog.animate = false;
        } else if (std.mem.eql(u8, arg, "--no-mouse")) {
            dialog.no_mouse = true;
        } else {
            return error.InvalidArguments;
        }
        index += 1;
    }

    if (!has_dialog) return error.InvalidArguments;
    if ((dialog.kind == .textbox or dialog.kind == .presentation) and dialog.text.len == 0) return error.InvalidArguments;

    const remaining = args.len - positional_start;
    switch (dialog.kind) {
        .message, .yesno, .infobox, .textbox, .presentation => {
            if (remaining != 2) return error.InvalidArguments;
            dialog.height = try requiredU16(args[positional_start]);
            dialog.width = try requiredU16(args[positional_start + 1]);
        },
        .input, .password => {
            if (remaining != 2 and remaining != 3) return error.InvalidArguments;
            dialog.height = try requiredU16(args[positional_start]);
            dialog.width = try requiredU16(args[positional_start + 1]);
            if (remaining == 3) dialog.initial_input = args[positional_start + 2];
        },
        .form => {
            if (remaining < 4 or (remaining - 2) % 2 != 0) return error.InvalidArguments;
            dialog.height = try requiredU16(args[positional_start]);
            dialog.width = try requiredU16(args[positional_start + 1]);
            var fields: std.ArrayList(FormField) = .empty;
            var field_index = positional_start + 2;
            while (field_index < args.len) : (field_index += 2) {
                try fields.append(allocator, .{ .label = args[field_index], .initial = args[field_index + 1] });
            }
            dialog.fields = try fields.toOwnedSlice(allocator);
        },
        .menu, .checklist, .radiolist => {
            if (remaining < 5) return error.InvalidArguments;
            dialog.height = try requiredU16(args[positional_start]);
            dialog.width = try requiredU16(args[positional_start + 1]);
            dialog.list_height = try requiredU16(args[positional_start + 2]);
            const item_start = positional_start + 3;
            const fields_per_item: usize = if (dialog.kind == .menu) 2 else 3;
            const item_fields = args.len - item_start;
            if (item_fields == 0 or item_fields % fields_per_item != 0) return error.InvalidArguments;
            var items: std.ArrayList(Item) = .empty;
            var item_index = item_start;
            while (item_index < args.len) : (item_index += fields_per_item) {
                const checked = if (fields_per_item == 3)
                    std.ascii.eqlIgnoreCase(args[item_index + 2], "on")
                else
                    false;
                try items.append(allocator, .{
                    .tag = args[item_index],
                    .description = args[item_index + 1],
                    .checked = checked,
                });
            }
            dialog.items = try items.toOwnedSlice(allocator);
        },
        .gauge => {
            if (remaining != 3) return error.InvalidArguments;
            dialog.height = try requiredU16(args[positional_start]);
            dialog.width = try requiredU16(args[positional_start + 1]);
            dialog.initial_percent = try std.fmt.parseUnsigned(u8, args[positional_start + 2], 10);
            if (dialog.initial_percent > 100) return error.InvalidArguments;
        },
    }

    if (dialog.width == 0 or dialog.height == 0) return error.InvalidArguments;
    if (dialog.kind == .menu or dialog.kind == .radiolist) {
        if (dialog.default_item) |wanted| {
            var found = false;
            for (dialog.items) |item| {
                if (std.mem.eql(u8, item.tag, wanted)) found = true;
            }
            if (!found) return error.InvalidArguments;
        }
    }
    return dialog;
}

fn kindForOption(option: []const u8) ?Kind {
    if (std.mem.eql(u8, option, "--msgbox")) return .message;
    if (std.mem.eql(u8, option, "--yesno")) return .yesno;
    if (std.mem.eql(u8, option, "--infobox")) return .infobox;
    if (std.mem.eql(u8, option, "--inputbox")) return .input;
    if (std.mem.eql(u8, option, "--passwordbox")) return .password;
    if (std.mem.eql(u8, option, "--form")) return .form;
    if (std.mem.eql(u8, option, "--menu")) return .menu;
    if (std.mem.eql(u8, option, "--presentation")) return .presentation;
    if (std.mem.eql(u8, option, "--checklist")) return .checklist;
    if (std.mem.eql(u8, option, "--radiolist")) return .radiolist;
    if (std.mem.eql(u8, option, "--textbox")) return .textbox;
    if (std.mem.eql(u8, option, "--gauge")) return .gauge;
    return null;
}

fn parseEnum(comptime T: type, value: []const u8) ?T {
    inline for (std.meta.fields(T)) |field| {
        if (std.ascii.eqlIgnoreCase(value, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn requiredU16(value: []const u8) !u16 {
    return std.fmt.parseUnsigned(u16, value, 10) catch error.InvalidArguments;
}

test "inputbox uses whiptail's text height width init order" {
    const args = [_][]const u8{ "--inputbox", "Name", "8", "60", "Ada Lovelace" };
    const dialog = try parse(std.testing.allocator, &args);
    try std.testing.expectEqual(Kind.input, dialog.kind);
    try std.testing.expectEqual(@as(?u16, 8), dialog.height);
    try std.testing.expectEqual(@as(?u16, 60), dialog.width);
    try std.testing.expectEqualStrings("Ada Lovelace", dialog.initial_input);
}

test "menu parses whiptail dimensions and default item" {
    const args = [_][]const u8{ "--default-item", "b", "--menu", "Pick", "12", "58", "4", "a", "Alpha", "b", "Beta" };
    const dialog = try parse(std.testing.allocator, &args);
    defer std.testing.allocator.free(dialog.items);
    try std.testing.expectEqual(Kind.menu, dialog.kind);
    try std.testing.expectEqual(@as(?u16, 4), dialog.list_height);
    try std.testing.expectEqualStrings("b", dialog.default_item.?);
    try std.testing.expectEqualStrings("Beta", dialog.items[1].description);
}

test "gauge accepts initial percent and presentation flags" {
    const args = [_][]const u8{ "--theme", "sunset", "--glyphs", "nerd", "--gauge", "Installing", "8", "54", "35" };
    const dialog = try parse(std.testing.allocator, &args);
    try std.testing.expectEqual(Kind.gauge, dialog.kind);
    try std.testing.expectEqual(@as(u8, 35), dialog.initial_percent);
    try std.testing.expectEqual(Theme.sunset, dialog.theme);
    try std.testing.expectEqual(Glyphs.nerd, dialog.glyphs);
}

test "checklist status and legacy presentation options are retained" {
    const args = [_][]const u8{ "--backtitle", "Setup", "--noitem", "--clear", "--fb", "--checklist", "Pick", "12", "50", "5", "a", "Alpha", "on" };
    const dialog = try parse(std.testing.allocator, &args);
    defer std.testing.allocator.free(dialog.items);
    try std.testing.expectEqualStrings("Setup", dialog.backtitle.?);
    try std.testing.expect(dialog.no_items);
    try std.testing.expect(dialog.clear_on_exit);
    try std.testing.expect(dialog.full_buttons);
    try std.testing.expect(dialog.items[0].checked);
}

test "invalid dimensions and list tuples are rejected" {
    const bad_input = [_][]const u8{ "--inputbox", "Name", "Ada", "8", "60" };
    const bad_menu = [_][]const u8{ "--menu", "Pick", "10", "40", "4", "a", "Alpha", "extra" };
    try std.testing.expectError(error.InvalidArguments, parse(std.testing.allocator, &bad_input));
    try std.testing.expectError(error.InvalidArguments, parse(std.testing.allocator, &bad_menu));
}

test "form parses paired field labels and initial values" {
    const args = [_][]const u8{ "--form", "Connection settings", "12", "64", "Host", "localhost", "Port", "8080" };
    const dialog = try parse(std.testing.allocator, &args);
    defer std.testing.allocator.free(dialog.fields);
    try std.testing.expectEqual(Kind.form, dialog.kind);
    try std.testing.expectEqual(@as(usize, 2), dialog.fields.len);
    try std.testing.expectEqualStrings("Port", dialog.fields[1].label);
    try std.testing.expectEqualStrings("8080", dialog.fields[1].initial);
}
