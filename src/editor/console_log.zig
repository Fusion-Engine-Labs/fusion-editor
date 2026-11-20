//! The text behind the Console panel: a fixed ring of recent log lines.
//!
//! Everything logged through `std.log` lands here (see `logFn`), from any
//! thread: the editor, the runtime, asset loaders, the game library, and the
//! game build. Nothing allocates, so it is safe to call from a log handler.

const std = @import("std");

const ConsoleLog = @This();

pub const Level = enum { err, warn, info, debug };

pub const max_line_bytes = 200;
pub const capacity = 512;

pub const Line = struct {
    level: Level = .info,
    len: u8 = 0,
    bytes: [max_line_bytes]u8 = undefined,

    pub fn text(self: *const Line) []const u8 {
        return self.bytes[0..self.len];
    }
};

lines: [capacity]Line = @splat(.{}),
/// Index of the oldest line.
start: usize = 0,
count: usize = 0,
error_count: usize = 0,
/// Bumped on every change, so readers can skip work when nothing happened.
revision_number: u64 = 0,
locked: std.atomic.Value(bool) = .init(false),

/// The log every `std.log` call in the process feeds.
pub var global: ConsoleLog = .{};

comptime {
    std.debug.assert(max_line_bytes <= std.math.maxInt(u8));
}

fn lock(self: *ConsoleLog) void {
    while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
}

fn unlock(self: *ConsoleLog) void {
    self.locked.store(false, .release);
}

/// Appends `message`, one entry per line of text. Lines longer than
/// `max_line_bytes` are cut; empty lines are dropped.
pub fn append(self: *ConsoleLog, level: Level, message: []const u8) void {
    self.lock();
    defer self.unlock();

    var parts = std.mem.splitScalar(u8, message, '\n');
    while (parts.next()) |part| {
        const trimmed = std.mem.trimEnd(u8, part, "\r \t");
        if (trimmed.len == 0) continue;
        self.pushLocked(level, trimmed);
    }
}

pub fn print(self: *ConsoleLog, level: Level, comptime format: []const u8, args: anytype) void {
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.print(format, args) catch {};
    self.append(level, writer.buffered());
}

fn pushLocked(self: *ConsoleLog, level: Level, text: []const u8) void {
    const index = (self.start + self.count) % capacity;
    if (self.count == capacity) {
        if (self.lines[self.start].level == .err) self.error_count -= 1;
        self.start = (self.start + 1) % capacity;
    } else {
        self.count += 1;
    }

    const line = &self.lines[index];
    const len = @min(text.len, max_line_bytes);
    line.level = level;
    line.len = @intCast(len);
    @memcpy(line.bytes[0..len], text[0..len]);
    if (level == .err) self.error_count += 1;
    self.revision_number +%= 1;
}

pub fn clear(self: *ConsoleLog) void {
    self.lock();
    defer self.unlock();
    self.start = 0;
    self.count = 0;
    self.error_count = 0;
    self.revision_number +%= 1;
}

pub fn revision(self: *ConsoleLog) u64 {
    self.lock();
    defer self.unlock();
    return self.revision_number;
}

pub fn errorCount(self: *ConsoleLog) usize {
    self.lock();
    defer self.unlock();
    return self.error_count;
}

/// Copies the newest lines, oldest first, into `out` and returns how many
/// were written.
pub fn snapshot(self: *ConsoleLog, out: []Line) usize {
    self.lock();
    defer self.unlock();

    const n = @min(out.len, self.count);
    const first = self.count - n;
    for (out[0..n], 0..) |*line, i| {
        line.* = self.lines[(self.start + first + i) % capacity];
    }
    return n;
}

/// `std.Options.logFn`: keeps the normal stderr output and mirrors each
/// message into `global`.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    std.log.defaultLog(level, scope, format, args);

    const prefix = if (scope == .default) "" else @tagName(scope) ++ ": ";
    global.print(switch (level) {
        .err => .err,
        .warn => .warn,
        .info => .info,
        .debug => .debug,
    }, prefix ++ format, args);
}

const testing = std.testing;

test "append splits lines, drops blanks and counts errors" {
    var log: ConsoleLog = .{};
    log.append(.info, "first\n\nsecond\r\n");
    log.append(.err, "broken");

    var out: [8]Line = undefined;
    const n = log.snapshot(&out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("first", out[0].text());
    try testing.expectEqualStrings("second", out[1].text());
    try testing.expectEqualStrings("broken", out[2].text());
    try testing.expectEqual(Level.err, out[2].level);
    try testing.expectEqual(@as(usize, 1), log.errorCount());
    try testing.expectEqual(@as(u64, 3), log.revision());
}

test "print formats and long lines are cut to the line size" {
    var log: ConsoleLog = .{};
    log.print(.warn, "value {d}", .{42});
    const long: [max_line_bytes + 30]u8 = @splat('x');
    log.append(.info, &long);

    var out: [2]Line = undefined;
    try testing.expectEqual(@as(usize, 2), log.snapshot(&out));
    try testing.expectEqualStrings("value 42", out[0].text());
    try testing.expectEqual(Level.warn, out[0].level);
    try testing.expectEqual(@as(usize, max_line_bytes), out[1].text().len);
}

test "the ring keeps the newest lines and snapshot returns the tail" {
    var log: ConsoleLog = .{};
    log.append(.err, "oldest error");
    for (0..capacity) |i| log.print(.info, "line {d}", .{i});

    try testing.expectEqual(@as(usize, 0), log.errorCount());
    var out: [2]Line = undefined;
    try testing.expectEqual(@as(usize, 2), log.snapshot(&out));
    try testing.expectEqualStrings("line 510", out[0].text());
    try testing.expectEqualStrings("line 511", out[1].text());

    var all: [capacity + 4]Line = undefined;
    try testing.expectEqual(@as(usize, capacity), log.snapshot(&all));
    try testing.expectEqualStrings("line 0", all[0].text());

    log.clear();
    try testing.expectEqual(@as(usize, 0), log.snapshot(&out));
}
