const fusion = @import("fusion_runtime");
const zimp = @import("zimp");
const std = @import("std");

const ProjectState = @This();

project: *fusion.Project,
/// Recooks loose assets as sources change. Null in pack mode, which runs
/// from the already-built pack and needs no sources.
watch_handle: ?*zimp.WatchHandle,

pub fn init(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8, asset_source: fusion.AssetSource) !ProjectState {
    const project = try allocator.create(fusion.Project);
    errdefer allocator.destroy(project);

    project.* = try fusion.openProject(allocator, io, .{ .root_path = root_path, .asset_source = asset_source });
    errdefer project.deinit(allocator, io);

    const watch_handle: ?*zimp.WatchHandle = switch (asset_source) {
        .loose => try project.watchAssets(allocator, io),
        .pack => null,
    };
    errdefer if (watch_handle) |handle| project.stopWatchingAssets(handle);
    if (watch_handle) |handle| try handle.waitForInitialCook();

    return .{
        .project = project,
        .watch_handle = watch_handle,
    };
}

pub fn deinit(self: *ProjectState, allocator: std.mem.Allocator, io: std.Io) void {
    if (self.watch_handle) |handle| self.project.stopWatchingAssets(handle);
    self.project.deinit(allocator, io);
    allocator.destroy(self.project);
    self.* = undefined;
}
