const std = @import("std");
const dialog_mod = @import("dialog.zig");
const ui = @import("ui.zig");
pub const std_options: std.Options = .{ .log_level = .warn };

const help_text =
    \\ziptail — whiptail-compatible dialogs with adaptive terminal styling
    \\
    \\Usage: ziptail [OPTIONS] DIALOG
    \\
    \\Dialogs:
    \\  --msgbox TEXT HEIGHT WIDTH
    \\  --yesno TEXT HEIGHT WIDTH
    \\  --infobox TEXT HEIGHT WIDTH
    \\  --inputbox TEXT HEIGHT WIDTH [INIT]
    \\  --form TEXT HEIGHT WIDTH LABEL VALUE...
    \\  --passwordbox TEXT HEIGHT WIDTH [INIT]
    \\  --textbox FILE HEIGHT WIDTH
    \\  --menu TEXT HEIGHT WIDTH LISTHEIGHT [TAG ITEM]...
    \\  --checklist TEXT HEIGHT WIDTH LISTHEIGHT [TAG ITEM STATUS]...
    \\  --radiolist TEXT HEIGHT WIDTH LISTHEIGHT [TAG ITEM STATUS]...
    \\  --gauge TEXT HEIGHT WIDTH PERCENT  (read progress updates from stdin)
    \\  --presentation FILE HEIGHT WIDTH  Show linked presentation screens
    \\Presentation files use named [screen ID] sections and explicit next/previous links.
    \\
    \\Whiptail options:
    \\  --title TEXT                 Dialog title
    \\  --backtitle TEXT             Text above the dialog
    \\  --default-item TAG           Initial menu/radiolist selection
    \\  --defaultno                  Start yes/no on No
    \\  --yes-button TEXT            Change Yes label
    \\  --no-button TEXT             Change No label
    \\  --ok-button TEXT             Change accept label
    \\  --cancel-button TEXT         Change cancel label
    \\  --output-fd FD               Send results to FD (default: 2)
    \\  --separate-output            Print checked tags one per line
    \\  --notags                     Hide item tags
    \\  --noitem                     Hide item descriptions
    \\  --nocancel                   Hide Cancel and ignore Escape
    \\  --fb, --fullbuttons          Use full-width buttons
    \\  --scrolltext                 Show a text scrollbar
    \\  --topleft                    Place the dialog in the top-left
    \\  --clear                      Clear the terminal after exit
    \\
    \\Presentation:
    \\  --theme auto|classic|aurora|sunset|mono
    \\  --glyphs auto|rounded|square|nerd|ascii
    \\  --image FILE                 Show on Kitty-graphics-compatible terminals
    \\  --no-animation               Disable entrance and spinner effects
    \\  --no-mouse                 Disable negotiated mouse support
    \\
    \\  -h, --help                   Show this help
    \\  -v, --version                Show version
    \\
    \\NO_COLOR disables color. TERM=linux selects a classic blue, ASCII-friendly style.
    \\Keys: Up/Down or j/k navigate · Space toggles · Enter accepts · Esc cancels
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const all_args = try init.minimal.args.toSlice(allocator);
    const args = if (all_args.len > 1) all_args[1..] else &.{ };

    if (args.len == 0 or args.len == 1 and (std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help"))) {
        try writeFile(init.io, std.Io.File.stdout(), help_text);
        return;
    }
    if (args.len == 1 and (std.mem.eql(u8, args[0], "--version") or std.mem.eql(u8, args[0], "-v"))) {
        try writeFile(init.io, std.Io.File.stdout(), "ziptail 0.1.0\n");
        return;
    }

    const dialog = dialog_mod.parse(allocator, args) catch {
        try writeFile(init.io, std.Io.File.stderr(), "ziptail: invalid arguments; use --help for usage\n");
        std.process.exit(2);
    };
    const outcome = try ui.run(init, &dialog);
    if (outcome.result == .escaped) std.process.exit(255);
    if (outcome.result == .cancelled) std.process.exit(1);

    const output = try buildOutput(allocator, &dialog, outcome);
    if (output) |text| {
        const file: std.Io.File = .{
            .handle = @intCast(dialog.output_fd),
            .flags = .{ .nonblocking = false },
        };
        try writeFile(init.io, file, text);
    }
}


fn writeFile(io: std.Io, file: std.Io.File, text: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.Writer.initStreaming(file, io, &buffer);
    try writer.interface.writeAll(text);
    try writer.flush();
}

fn buildOutput(allocator: std.mem.Allocator, dialog: *const dialog_mod.Dialog, outcome: ui.Outcome) !?[]const u8 {
    switch (dialog.kind) {
        .message, .yesno, .infobox, .textbox, .gauge, .presentation => return null,
        .input, .password => return outcome.input,
        .menu => return dialog.items[outcome.selected].tag,
        .radiolist => return dialog.items[outcome.selected].tag,
        .form => {
            var output: std.ArrayList(u8) = .empty;
            for (outcome.form_values, 0..) |value, i| {
                if (i > 0) try output.append(allocator, '\n');
                try output.appendSlice(allocator, value);
            }
            return try output.toOwnedSlice(allocator);
        },
        .checklist => {
            var output: std.ArrayList(u8) = .empty;
            var wrote = false;
            for (dialog.items, outcome.checks) |item, checked| {
                if (!checked) continue;
                if (wrote) {
                    if (dialog.separate_output) {
                        try output.append(allocator, '\n');
                    } else {
                        try output.append(allocator, ' ');
                    }
                }
                if (dialog.separate_output) {
                    try output.appendSlice(allocator, item.tag);
                } else {
                    try output.append(allocator, '"');
                    for (item.tag) |byte| {
                        if (byte == '"' or byte == '\\') try output.append(allocator, '\\');
                        try output.append(allocator, byte);
                    }
                    try output.append(allocator, '"');
                }
                wrote = true;
            }
            return try output.toOwnedSlice(allocator);
        },
    }
}
