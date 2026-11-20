const std = @import("std");
const ui = @import("zGUI");

const ConsoleLog = @import("../editor/console_log.zig");
const panel = @import("panel.zig");

pub const panel_id = panel.id("editor.console");
pub const descriptor: panel.Descriptor = .{
    .id = panel_id,
    .title = "Console",
    .min_size = .{ .x = 240, .y = 96 },
};

/// Only the newest lines get nodes; older ones stay in the log's ring.
const max_visible_lines = 200;
const line_height: f32 = 18;

const Console = @This();

log: *ConsoleLog,
root_node: ui.NodeId = ui.invalid_node,
body_node: ui.NodeId = ui.invalid_node,
list_node: ui.NodeId = ui.invalid_node,
clear_button: ui.NodeId = ui.invalid_node,
/// Log revision the list was last built from; null forces a rebuild.
shown_revision: ?u64 = null,
lines: [max_visible_lines]ConsoleLog.Line = undefined,
title_buffer: [40]u8 = undefined,
title_len: usize = 0,

pub fn init(log: *ConsoleLog) Console {
    return .{ .log = log };
}

pub fn mount(self: *Console, state: *ui.Ui, parent: ui.NodeId, _: panel.Services) !void {
    const root_node = try ui.widgets.column(state, parent, .{
        .width = .fill,
        .height = .fill,
        .gap = state.theme.space.sm,
        .padding = .{ .left = state.theme.space.xl, .right = state.theme.space.xl, .top = state.theme.space.lg, .bottom = state.theme.space.lg },
        .background = .shell,
        .border = .stroke_soft,
        .border_edges = .{ .top = 1 },
    });
    errdefer state.destroySubtree(root_node);

    const header = try ui.widgets.row(state, root_node, .{
        .width = .fill,
        .height = .{ .px = state.theme.metrics.compact_control_height },
        .gap = state.theme.space.sm,
    });
    _ = try ui.widgets.text(state, header, "Console", .{
        .width = .{ .px = 72 },
        .height = .fill,
        .padding = .{ .top = state.centeredTextTop(state.theme.metrics.compact_control_height, 16) },
        .size = 16,
    });
    _ = try ui.widgets.spacer(state, header);
    const clear_button = try ui.widgets.themedButton(state, header, "Clear", .{
        .height = .fill,
        .padding = .{ .left = 12, .right = 12, .top = 5, .bottom = 4 },
    });

    const body_node = try ui.widgets.column(state, root_node, .{
        .width = .fill,
        .height = .fill,
        .background = .transparent,
        .overflow_y = .scroll,
    });

    self.root_node = root_node;
    self.body_node = body_node;
    self.clear_button = clear_button;
    self.shown_revision = null;
    try self.refresh(state);
}

pub fn update(self: *Console, state: *ui.Ui, _: panel.Frame) !void {
    if (state.clicked(self.clear_button)) {
        self.log.clear();
    }
    try self.refresh(state);
}

pub fn unmount(self: *Console, state: *ui.Ui) void {
    state.destroySubtree(self.root_node);
    self.root_node = ui.invalid_node;
    self.body_node = ui.invalid_node;
    self.list_node = ui.invalid_node;
    self.clear_button = ui.invalid_node;
}

pub fn root(self: *const Console) ui.NodeId {
    return self.root_node;
}

/// The tab title, which carries the error count so a failed build is
/// noticeable while another tab is in front.
pub fn title(self: *const Console) []const u8 {
    return if (self.title_len == 0) descriptor.title else self.title_buffer[0..self.title_len];
}

fn refresh(self: *Console, state: *ui.Ui) !void {
    const revision = self.log.revision();
    if (self.shown_revision) |shown| {
        if (shown == revision) return;
    }
    self.shown_revision = revision;

    const errors = self.log.errorCount();
    const text: []const u8 = if (errors == 0)
        ""
    else
        std.fmt.bufPrint(&self.title_buffer, "Console ({d} errors)", .{errors}) catch "";
    self.title_len = text.len;

    try self.rebuildList(state);
}

fn rebuildList(self: *Console, state: *ui.Ui) !void {
    if (self.list_node != ui.invalid_node) state.destroySubtree(self.list_node);
    self.list_node = ui.invalid_node;

    const list_node = try ui.widgets.column(state, self.body_node, .{
        .width = .fill,
        .height = .hug,
        .background = .transparent,
    });
    errdefer state.destroySubtree(list_node);

    const count = self.log.snapshot(&self.lines);
    for (self.lines[0..count]) |*line| {
        _ = try ui.widgets.text(state, list_node, line.text(), .{
            .width = .fill,
            .height = .{ .px = line_height },
            .color = switch (line.level) {
                .err => .danger,
                .warn => .warning,
                .info => .text_dim,
                .debug => .text_muted,
            },
            .size = state.theme.font.small,
        });
    }
    self.list_node = list_node;

    // Keep the newest line in view.
    if (state.tree.get(self.body_node)) |body| {
        const visible = if (state.bounds(self.body_node)) |bounds| bounds.h else 0;
        const offset = @max(0, @as(f32, @floatFromInt(count)) * line_height - visible);
        body.scroll_offset.y = offset;
        body.scroll_target_offset.y = offset;
    }
}

test "the console lists log lines and reports errors in its title" {
    var log: ConsoleLog = .{};
    log.append(.info, "building game");

    var state = try ui.Ui.init(std.testing.allocator);
    defer state.deinit();
    var registry = @import("../editor/actions.zig").Registry.init(std.testing.allocator);
    defer registry.deinit();

    var console = Console.init(&log);
    try console.mount(&state, state.rootNode(), .{ .actions = &registry });
    defer console.unmount(&state);

    try std.testing.expectEqualStrings("Console", console.title());

    log.append(.err, "src/game.zig:3:5: error: expected ';'\nsecond line");
    try console.update(&state, .{});
    try std.testing.expectEqualStrings("Console (2 errors)", console.title());

    // Nothing changed, so the list is left alone.
    const list = console.list_node;
    try console.update(&state, .{});
    try std.testing.expectEqual(list, console.list_node);

    log.clear();
    try console.update(&state, .{});
    try std.testing.expectEqualStrings("Console", console.title());
}
