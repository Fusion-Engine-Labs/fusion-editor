//! Builds the project's game package and owns the loaded game library.
//!
//! A build runs `zig build` in the project root on another task, so the
//! editor keeps drawing. Each finished build is copied to its own file
//! before it is opened: the build output path is overwritten by the next
//! build, and a library that is still mapped must not change underneath us.

const fusion = @import("fusion_runtime");
const std = @import("std");

const log = @import("../utilities/log.zig");

const GameLibrary = fusion.game_module.GameLibrary;

const GameCode = @This();

/// Directory, inside the project's generated directory, for library copies.
const copies_dir_name = "game";

allocator: std.mem.Allocator,
io: std.Io,
project: *const fusion.Project,
/// The library the runtime is using. Heap-allocated so sessions can keep a
/// pointer to it while a newer build is being installed.
library: ?*Loaded = null,
/// The library `poll` handed out, until `install` or `discard` claims it.
pending: ?*Loaded = null,
/// Numbers the library copies of this editor run.
generation: u32 = 0,
job: ?*BuildJob = null,

const Loaded = struct {
    library: GameLibrary,
    /// The copy this library was opened from, relative to the project root.
    copy_path: []u8,
};

const BuildJob = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Absolute project root; the build's working directory.
    root_path: [:0]u8,
    future: std.Io.Future(void) = undefined,
    done: std.atomic.Value(bool) = .init(false),
    result: ?std.process.RunResult = null,
    failure: ?anyerror = null,

    fn run(job: *BuildJob) void {
        job.result = std.process.run(job.allocator, job.io, .{
            .argv = &.{ "zig", "build" },
            .cwd = .{ .path = job.root_path },
        }) catch |err| failed: {
            job.failure = err;
            break :failed null;
        };
        job.done.store(true, .release);
    }

    fn destroy(job: *BuildJob) void {
        if (job.result) |result| {
            job.allocator.free(result.stdout);
            job.allocator.free(result.stderr);
        }
        job.allocator.free(job.root_path);
        job.allocator.destroy(job);
    }
};

pub const Poll = union(enum) {
    /// No build is running and none has finished since the last poll.
    idle,
    building,
    /// The build or the load failed; the reason has been logged.
    failed,
    /// A new library is open. Pass it to `install` or `discard`.
    built: *const GameLibrary,
};

pub fn init(allocator: std.mem.Allocator, io: std.Io, project: *const fusion.Project) GameCode {
    var self: GameCode = .{ .allocator = allocator, .io = io, .project = project };
    self.removeCopies();
    return self;
}

/// Call only after every session that used the library has been destroyed.
pub fn deinit(self: *GameCode) void {
    self.cancelBuild();
    if (self.pending) |loaded| self.unload(loaded);
    if (self.library) |loaded| self.unload(loaded);
    self.* = undefined;
}

/// True when the project declares a game library and has a build script to
/// produce it.
pub fn hasPackage(self: *const GameCode) bool {
    if (self.project.manifest.game_library == null) return false;
    self.project.root_dir.access(self.io, "build.zig", .{}) catch return false;
    return true;
}

pub fn isBuilding(self: *const GameCode) bool {
    return self.job != null;
}

pub fn current(self: *const GameCode) ?*const GameLibrary {
    return if (self.library) |loaded| &loaded.library else null;
}

/// Opens the library a previous build left behind, without building. Returns
/// null, after logging why, if there is none or it cannot be used.
pub fn loadExisting(self: *GameCode) ?*const GameLibrary {
    if (self.project.manifest.game_library == null) return null;

    const loaded = self.loadArtifact() catch |err| {
        switch (err) {
            error.FileNotFound => log.info("game library has not been built yet; press Play to build it", .{}),
            else => log.warn("existing game library cannot be used ({s}); press Play to rebuild it", .{@errorName(err)}),
        }
        return null;
    };
    self.library = loaded;
    return &loaded.library;
}

/// Starts `zig build` in the project root. Poll for the result.
pub fn requestBuild(self: *GameCode) !void {
    if (self.job != null) return error.BuildInProgress;

    const root_path = try self.project.root_dir.realPathFileAlloc(self.io, ".", self.allocator);
    errdefer self.allocator.free(root_path);

    const job = try self.allocator.create(BuildJob);
    errdefer self.allocator.destroy(job);
    job.* = .{ .allocator = self.allocator, .io = self.io, .root_path = root_path };
    job.future = try self.io.concurrent(BuildJob.run, .{job});

    self.job = job;
    log.info("building game: zig build ({s})", .{root_path});
}

/// Stops a running build and throws its result away.
pub fn cancelBuild(self: *GameCode) void {
    const job = self.job orelse return;
    self.job = null;
    job.future.cancel(self.io);
    job.destroy();
}

/// Reports the build's progress. When it has finished, logs its output and,
/// on success, opens the new library next to the current one.
pub fn poll(self: *GameCode) Poll {
    const job = self.job orelse return .idle;
    if (!job.done.load(.acquire)) return .building;

    self.job = null;
    job.future.await(self.io);
    defer job.destroy();

    if (job.failure) |err| {
        log.err("could not run `zig build`: {s}", .{@errorName(err)});
        return .failed;
    }

    const result = job.result.?;
    if (!result.term.success()) {
        log.err("game build failed:\n{s}", .{result.stderr});
        return .failed;
    }
    if (result.stderr.len != 0) log.info("{s}", .{result.stderr});

    const loaded = self.loadArtifact() catch |err| {
        log.err("built game library cannot be loaded: {s}", .{@errorName(err)});
        return .failed;
    };
    self.pending = loaded;
    log.info("game build succeeded", .{});
    return .{ .built = &loaded.library };
}

/// Makes the library returned by `poll` the current one and closes the one
/// it replaces. Call only after no session uses the previous library.
pub fn install(self: *GameCode, library: *const GameLibrary) void {
    const loaded = self.takePending(library);
    if (self.library) |previous| self.unload(previous);
    self.library = loaded;
}

/// Closes a library returned by `poll` that will not be used.
pub fn discard(self: *GameCode, library: *const GameLibrary) void {
    self.unload(self.takePending(library));
}

fn takePending(self: *GameCode, library: *const GameLibrary) *Loaded {
    const loaded = self.pending.?;
    std.debug.assert(&loaded.library == library);
    self.pending = null;
    return loaded;
}

/// Copies the build output to a fresh file and opens that copy.
fn loadArtifact(self: *GameCode) !*Loaded {
    const manifest = &self.project.manifest;
    const artifact = manifest.game_library orelse return error.NoGameLibrary;
    const root = self.project.root_dir;

    const copies_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ manifest.generated_dir, copies_dir_name });
    defer self.allocator.free(copies_dir);
    try root.createDirPath(self.io, copies_dir);

    self.generation += 1;
    const copy_path = try std.fmt.allocPrint(self.allocator, "{s}/{d}-{s}", .{
        copies_dir,
        self.generation,
        std.fs.path.basename(artifact),
    });
    errdefer self.allocator.free(copy_path);

    try root.copyFile(artifact, root, copy_path, self.io, .{});
    errdefer root.deleteFile(self.io, copy_path) catch {};

    const absolute = try root.realPathFileAlloc(self.io, copy_path, self.allocator);
    defer self.allocator.free(absolute);

    const loaded = try self.allocator.create(Loaded);
    errdefer self.allocator.destroy(loaded);
    loaded.* = .{ .library = try GameLibrary.open(absolute), .copy_path = copy_path };
    return loaded;
}

fn unload(self: *GameCode, loaded: *Loaded) void {
    loaded.library.deinit();
    self.project.root_dir.deleteFile(self.io, loaded.copy_path) catch {};
    self.allocator.free(loaded.copy_path);
    self.allocator.destroy(loaded);
}

/// Library copies from an editor run that did not shut down cleanly.
fn removeCopies(self: *GameCode) void {
    const copies_dir = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.project.manifest.generated_dir, copies_dir_name }) catch return;
    defer self.allocator.free(copies_dir);
    self.project.root_dir.deleteTree(self.io, copies_dir) catch {};
}

const testing = std.testing;

fn testProject(dir: std.Io.Dir, game_library: ?[]const u8) fusion.Project {
    var manifest: fusion.ProjectManifest = .{
        .name = "Test",
        .project_id = .parseComptime("bf5a424f-e93e-4977-9a7a-0c522318dfdc"),
    };
    manifest.game_library = game_library;
    return .{ .manifest = manifest, .root_dir = dir };
}

test "a project needs both a declared library and a build script to count as a package" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const bare = testProject(tmp.dir, null);
    var none = GameCode.init(testing.allocator, testing.io, &bare);
    defer none.deinit();
    try testing.expect(!none.hasPackage());
    try testing.expect(none.loadExisting() == null);
    try testing.expectEqual(Poll.idle, none.poll());

    const declared = testProject(tmp.dir, "zig-out/lib/libgame.so");
    var game = GameCode.init(testing.allocator, testing.io, &declared);
    defer game.deinit();
    try testing.expect(!game.hasPackage());
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "build.zig", .data = "" });
    try testing.expect(game.hasPackage());
    try testing.expect(!game.isBuilding());
    try testing.expect(game.current() == null);
}

test "a missing or unusable library is reported as absent rather than failing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = testProject(tmp.dir, "zig-out/lib/libgame.so");
    var game = GameCode.init(testing.allocator, testing.io, &project);
    defer game.deinit();

    try testing.expect(game.loadExisting() == null);

    try tmp.dir.createDirPath(testing.io, "zig-out/lib");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "zig-out/lib/libgame.so", .data = "not a library" });
    try testing.expect(game.loadExisting() == null);
    try testing.expect(game.current() == null);
    // The rejected copy is removed again.
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, ".fusion/game/2-libgame.so", .{}));
}

test "stale library copies are removed when the project is opened" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, ".fusion/game");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".fusion/game/7-libgame.so", .data = "stale" });

    const project = testProject(tmp.dir, "zig-out/lib/libgame.so");
    var game = GameCode.init(testing.allocator, testing.io, &project);
    defer game.deinit();
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, ".fusion/game/7-libgame.so", .{}));
}
