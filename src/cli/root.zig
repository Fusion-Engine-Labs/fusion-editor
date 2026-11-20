const std = @import("std");
const fusion = @import("fusion_runtime");

const default_project_name = "Fusion Game Example";

pub const Options = struct {
    root_path: []const u8 = ".",
    create_project: bool = false,
    project_name: []const u8 = default_project_name,
    /// `create <path> --sdk-path <dir>` points the new project's game package
    /// at a local SDK checkout instead of the published one.
    sdk_path: ?[]const u8 = null,
    /// `open <path> --pack` loads cooked assets from the project's pack, the
    /// way a shipped game does, instead of the loose cooked directory.
    asset_source: fusion.AssetSource = .loose,
};

pub fn parse(args: []const []const u8) !Options {
    var options: Options = .{};

    if (args.len == 1) {
        return error.MissingProjectPath;
    }

    if (args.len == 2) {
        if (std.mem.eql(u8, args[1], "create") or std.mem.eql(u8, args[1], "open")) {
            return error.MissingProjectPath;
        }
        return error.UnknownArgument;
    }

    options.root_path = args[2];
    const flags = args[3..];
    if (std.mem.eql(u8, args[1], "create")) {
        options.create_project = true;
        switch (flags.len) {
            0 => {},
            1 => return if (std.mem.eql(u8, flags[0], "--sdk-path")) error.MissingSdkPath else error.UnknownArgument,
            2 => {
                if (!std.mem.eql(u8, flags[0], "--sdk-path")) return error.UnknownArgument;
                options.sdk_path = flags[1];
            },
            else => return error.UnknownArgument,
        }
    } else if (std.mem.eql(u8, args[1], "open")) {
        switch (flags.len) {
            0 => {},
            1 => {
                if (!std.mem.eql(u8, flags[0], "--pack")) return error.UnknownArgument;
                options.asset_source = .pack;
            },
            else => return error.UnknownArgument,
        }
    } else {
        return error.UnknownArgument;
    }

    return options;
}

pub fn absoluteProjectRoot(allocator: std.mem.Allocator, io: std.Io, root: []const u8) ![:0]u8 {
    if (std.fs.path.isAbsolute(root)) {
        return allocator.dupeSentinel(u8, root, '\x00');
    }

    return std.Io.Dir.cwd().realPathFileAlloc(io, root, allocator);
}

const testing = std.testing;

test "parse rejects a missing project path" {
    try testing.expectError(error.MissingProjectPath, parse(&.{"fusion-editor"}));
}

test "parse create command selects create mode" {
    const options = try parse(&.{ "fusion-editor", "create", "/tmp/project" });

    try testing.expectEqualStrings("/tmp/project", options.root_path);
    try testing.expect(options.create_project);
    try testing.expect(options.sdk_path == null);
}

test "parse create --sdk-path selects a local SDK checkout" {
    const options = try parse(&.{ "fusion-editor", "create", "/tmp/project", "--sdk-path", "../fusion-sdk" });

    try testing.expect(options.create_project);
    try testing.expectEqualStrings("../fusion-sdk", options.sdk_path.?);
    try testing.expectError(error.MissingSdkPath, parse(&.{ "fusion-editor", "create", "/tmp/project", "--sdk-path" }));
    try testing.expectError(error.UnknownArgument, parse(&.{ "fusion-editor", "create", "/tmp/project", "--sdk-path", "a", "b" }));
    try testing.expectError(error.UnknownArgument, parse(&.{ "fusion-editor", "open", "/tmp/project", "--sdk-path", "a" }));
}

test "parse open command selects open mode" {
    const options = try parse(&.{ "fusion-editor", "open", "/tmp/project" });

    try testing.expectEqualStrings("/tmp/project", options.root_path);
    try testing.expect(!options.create_project);
}

test "parse rejects commands without a project path" {
    try testing.expectError(error.MissingProjectPath, parse(&.{ "fusion-editor", "create" }));
    try testing.expectError(error.MissingProjectPath, parse(&.{ "fusion-editor", "open" }));
}

test "parse rejects unknown arguments" {
    try testing.expectError(error.UnknownArgument, parse(&.{ "fusion-editor", "wat" }));
    try testing.expectError(error.UnknownArgument, parse(&.{ "fusion-editor", "wat", "/tmp/project" }));
    try testing.expectError(error.UnknownArgument, parse(&.{ "fusion-editor", "open", "/tmp/project", "extra" }));
    try testing.expectError(error.UnknownArgument, parse(&.{ "fusion-editor", "create", "/tmp/project", "--pack" }));
    try testing.expectError(error.UnknownArgument, parse(&.{ "fusion-editor", "open", "/tmp/project", "--pack", "extra" }));
}

test "parse open --pack loads assets from the project's pack" {
    const options = try parse(&.{ "fusion-editor", "open", "/tmp/project", "--pack" });
    try testing.expectEqualStrings("/tmp/project", options.root_path);
    try testing.expectEqual(fusion.AssetSource.pack, options.asset_source);
    try testing.expectEqual(fusion.AssetSource.loose, (try parse(&.{ "fusion-editor", "open", "/tmp/project" })).asset_source);
}
