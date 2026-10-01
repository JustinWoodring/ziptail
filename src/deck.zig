const std = @import("std");

pub const Transition = enum { cut, fade, slide_left, slide_right };
pub const Scale = enum { normal, large };

pub const Screen = struct {
    id: []const u8,
    title: []const u8,
    body: []const u8,
    body_env: ?[]const u8 = null,
    next: ?[]const u8 = null,
    previous: ?[]const u8 = null,
    result_env: ?[]const u8 = null,
    success: ?[]const u8 = null,
    failure: ?[]const u8 = null,
    transition: Transition = .fade,
    scale: Scale = .normal,

    pub fn bodyText(self: Screen, env: *std.process.Environ.Map) []const u8 {
        if (self.body_env) |key| return env.get(key) orelse "";
        return self.body;
    }
};

pub const Deck = struct {
    title: []const u8,
    start: usize,
    screens: []Screen,
    result_env: ?[]const u8 = null,
    success_start: ?[]const u8 = null,
    failure_start: ?[]const u8 = null,

    pub fn find(self: Deck, id: []const u8) ?usize {
        for (self.screens, 0..) |screen, index| {
            if (std.mem.eql(u8, screen.id, id)) return index;
        }
        return null;
    }

    pub fn initialScreen(self: Deck, env: *std.process.Environ.Map) usize {
        if (self.result_env) |key| {
            const result = env.get(key) orelse "";
            const target = if (isSuccessResult(result)) self.success_start else self.failure_start;
            if (target) |id| return self.find(id) orelse self.start;
        }
        return self.start;
    }

    pub fn next(self: Deck, index: usize, env: *std.process.Environ.Map) ?usize {
        const screen = self.screens[index];
        if (screen.result_env) |key| {
            const result = env.get(key) orelse "";
            const target = if (isSuccessResult(result)) screen.success else screen.failure;
            if (target) |id| return self.find(id);
        }
        if (screen.next) |id| return self.find(id);
        return null;
    }

    pub fn previous(self: Deck, index: usize) ?usize {
        const target = self.screens[index].previous orelse return null;
        return self.find(target);
    }
};

fn isSuccessResult(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "success") or
        std.ascii.eqlIgnoreCase(value, "ok") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.mem.eql(u8, value, "0");
}

const MutableScreen = struct {
    id: []const u8,
    title: ?[]const u8 = null,
    body: std.ArrayList(u8) = .empty,
    body_env: ?[]const u8 = null,
    next: ?[]const u8 = null,
    previous: ?[]const u8 = null,
    result_env: ?[]const u8 = null,
    success: ?[]const u8 = null,
    failure: ?[]const u8 = null,
    transition: Transition = .fade,
    scale: Scale = .normal,
    body_started: bool = false,
};

const Section = union(enum) { none, deck, screen: usize };

/// Parses the small INI-like `.zdeck` format. Screen bodies begin at `---` and
/// continue until the next `[screen ID]` section.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Deck {
    var title: []const u8 = "ziptail presentation";
    var start_id: ?[]const u8 = null;
    var result_env: ?[]const u8 = null;
    var success_start: ?[]const u8 = null;
    var failure_start: ?[]const u8 = null;
    var section: Section = .none;
    var mutable_screens: std.ArrayList(MutableScreen) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');

    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 and !isBody(section, &mutable_screens)) continue;

        if (std.mem.eql(u8, line, "[deck]")) {
            section = .deck;
            continue;
        }
        if (std.mem.startsWith(u8, line, "[screen ") and std.mem.endsWith(u8, line, "]")) {
            const id = std.mem.trim(u8, line[8 .. line.len - 1], " \t");
            if (id.len == 0) return error.InvalidDeck;
            try mutable_screens.append(allocator, .{ .id = id });
            section = .{ .screen = mutable_screens.items.len - 1 };
            continue;
        }

        switch (section) {
            .none => return error.InvalidDeck,
            .deck => {
                const assignment = try splitAssignment(line);
                if (std.mem.eql(u8, assignment.key, "title")) {
                    title = assignment.value;
                } else if (std.mem.eql(u8, assignment.key, "start")) {
                    start_id = assignment.value;
                } else if (std.mem.eql(u8, assignment.key, "result_env")) {
                    result_env = assignment.value;
                } else if (std.mem.eql(u8, assignment.key, "success_start")) {
                    success_start = assignment.value;
                } else if (std.mem.eql(u8, assignment.key, "failure_start")) {
                    failure_start = assignment.value;
                } else {
                    return error.InvalidDeck;
                }
            },
            .screen => |index| {
                var screen = &mutable_screens.items[index];
                if (screen.body_started) {
                    try appendBody(allocator, &screen.body, std.mem.trimEnd(u8, raw, "\r"));
                } else if (std.mem.eql(u8, line, "---")) {
                    screen.body_started = true;
                } else if (std.mem.indexOfScalar(u8, line, '=')) |_| {
                    try setScreenField(screen, try splitAssignment(line));
                } else {
                    screen.body_started = true;
                    try appendBody(allocator, &screen.body, std.mem.trimEnd(u8, raw, "\r"));
                }
            },
        }
    }

    if (mutable_screens.items.len == 0) return error.InvalidDeck;
    const screens = try allocator.alloc(Screen, mutable_screens.items.len);
    for (mutable_screens.items, 0..) |*mutable, index| {
        screens[index] = .{
            .id = mutable.id,
            .title = mutable.title orelse mutable.id,
            .body = try mutable.body.toOwnedSlice(allocator),
            .body_env = mutable.body_env,
            .next = mutable.next,
            .previous = mutable.previous,
            .result_env = mutable.result_env,
            .success = mutable.success,
            .failure = mutable.failure,
            .transition = mutable.transition,
            .scale = mutable.scale,
        };
    }

    var deck: Deck = .{
        .title = title,
        .start = 0,
        .screens = screens,
        .result_env = result_env,
        .success_start = success_start,
        .failure_start = failure_start,
    };
    if (start_id) |id| deck.start = deck.find(id) orelse return error.InvalidDeck;
    for (deck.screens, 0..) |screen, index| {
        for (deck.screens[0..index]) |earlier| {
            if (std.mem.eql(u8, screen.id, earlier.id)) return error.InvalidDeck;
        }
        if (screen.result_env != null and (screen.success == null or screen.failure == null)) return error.InvalidDeck;
        if (screen.next) |id| if (deck.find(id) == null) return error.InvalidDeck;
        if (screen.previous) |id| if (deck.find(id) == null) return error.InvalidDeck;
        if (screen.success) |id| if (deck.find(id) == null) return error.InvalidDeck;
        if (screen.failure) |id| if (deck.find(id) == null) return error.InvalidDeck;
    }
    if (deck.result_env != null) {
        const success = deck.success_start orelse return error.InvalidDeck;
        const failure = deck.failure_start orelse return error.InvalidDeck;
        if (deck.find(success) == null or deck.find(failure) == null) return error.InvalidDeck;
    }
    return deck;
}

const Assignment = struct { key: []const u8, value: []const u8 };

fn splitAssignment(line: []const u8) !Assignment {
    const equal = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidDeck;
    const key = std.mem.trim(u8, line[0..equal], " \t");
    const value = unquote(std.mem.trim(u8, line[equal + 1 ..], " \t\r"));
    if (key.len == 0) return error.InvalidDeck;
    return .{ .key = key, .value = value };
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') return value[1 .. value.len - 1];
    return value;
}

fn isBody(section: Section, screens: *const std.ArrayList(MutableScreen)) bool {
    return switch (section) {
        .screen => |index| screens.items[index].body_started,
        else => false,
    };
}

fn appendBody(allocator: std.mem.Allocator, body: *std.ArrayList(u8), line: []const u8) !void {
    if (body.items.len != 0) try body.append(allocator, '\n');
    try body.appendSlice(allocator, line);
}

fn setScreenField(screen: *MutableScreen, assignment: Assignment) !void {
    if (std.mem.eql(u8, assignment.key, "title")) {
        screen.title = assignment.value;
    } else if (std.mem.eql(u8, assignment.key, "next")) {
        screen.next = assignment.value;
    } else if (std.mem.eql(u8, assignment.key, "previous")) {
        screen.previous = assignment.value;
    } else if (std.mem.eql(u8, assignment.key, "success")) {
        screen.success = assignment.value;
    } else if (std.mem.eql(u8, assignment.key, "failure")) {
        screen.failure = assignment.value;
    } else if (std.mem.eql(u8, assignment.key, "result_env")) {
        screen.result_env = assignment.value;
    } else if (std.mem.eql(u8, assignment.key, "body_env")) {
        screen.body_env = assignment.value;
    } else if (std.mem.eql(u8, assignment.key, "transition")) {
        screen.transition = parseEnum(Transition, assignment.value) orelse return error.InvalidDeck;
    } else if (std.mem.eql(u8, assignment.key, "scale")) {
        screen.scale = parseEnum(Scale, assignment.value) orelse return error.InvalidDeck;
    } else {
        return error.InvalidDeck;
    }
}

fn parseEnum(comptime T: type, value: []const u8) ?T {
    inline for (std.meta.fields(T)) |field| {
        if (std.ascii.eqlIgnoreCase(value, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

test "deck parses linked screens and result branches" {
    const source =
        \\[deck]
        \\title = Install guide
        \\start = result
        \\
        \\[screen result]
        \\title = Installer output
        \\result_env = INSTALL_STATUS
        \\success = done
        \\failure = failed
        \\transition = slide_left
        \\body_env = INSTALL_LOG
        \\
        \\[screen done]
        \\title = Complete
        \\scale = large
        \\---
        \\Everything is ready.
        \\
        \\[screen failed]
        \\title = Failed
        \\previous = result
        \\---
        \\Review the installer output.
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try parse(arena.allocator(), source);
    try std.testing.expectEqualStrings("Install guide", deck.title);
    try std.testing.expectEqualStrings("result", deck.screens[deck.start].id);
    try std.testing.expectEqual(Transition.slide_left, deck.screens[0].transition);
    try std.testing.expectEqual(Scale.large, deck.screens[1].scale);
}

test "deck rejects unresolved links" {
    const source =
        \\[deck]
        \\[screen start]
        \\next = missing
        \\---
        \\Body.
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidDeck, parse(arena.allocator(), source));
}
test "deck chooses a start screen from installer status" {
    const source =
        \\[deck]
        \\start = result
        \\result_env = INSTALL_STATUS
        \\success_start = done
        \\failure_start = failed
        \\
        \\[screen result]
        \\title = Installer output
        \\---
        \\Output.
        \\
        \\[screen done]
        \\title = Succeeded
        \\
        \\[screen failed]
        \\title = Failed
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const deck = try parse(allocator, source);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("INSTALL_STATUS", "failure");
    try std.testing.expectEqualStrings("failed", deck.screens[deck.initialScreen(&env)].id);
    try env.put("INSTALL_STATUS", "success");
    try std.testing.expectEqualStrings("done", deck.screens[deck.initialScreen(&env)].id);
}
