//! The files a new project starts with, besides its manifest and scene.

const builtin = @import("builtin");
const std = @import("std");

/// Where a new project's `build.zig.zon` gets the SDK from.
pub const SdkDependency = union(enum) {
    /// A published SDK revision.
    remote: struct { url: []const u8, hash: []const u8 },
    /// A local SDK checkout, as an absolute path. For working on the SDK itself.
    path: []const u8,
};

/// The SDK revision this editor's runtime was built against. Keep both
/// strings identical to the `fusion_sdk` entry in fusion-runtime's
/// `build.zig.zon`: a game built against another revision is rejected at load.
pub const default_sdk: SdkDependency = .{ .remote = .{
    .url = "git+https://github.com/Fusion-Engine-Labs/fusion-sdk.git#e7311847a91536d10c47c52f150f4cb56076fc01",
    .hash = "fusion_sdk-0.0.0-tQKBDrgeAQCP_SN2sKcjLpTQwJKudIBE8Giw4PFasBeT",
} };

pub const package_name = "game";
pub const default_scene_path = "scenes/main.scene.json";

/// Where `build_zig` installs the library, relative to the project root.
pub const game_library_path = "zig-out/lib/lib" ++ package_name ++ switch (builtin.os.tag) {
    .macos => ".dylib",
    else => ".so",
};

pub const build_zig =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    const sdk = b.dependency("fusion_sdk", .{
    \\        .target = target,
    \\        .optimize = optimize,
    \\    });
    \\
    \\    const game_mod = b.createModule(.{
    \\        .root_source_file = b.path("src/root.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\        .pic = true,
    \\        .imports = &.{
    \\            .{ .name = "fusion_sdk", .module = sdk.module("fusion_sdk") },
    \\        },
    \\    });
    \\
    \\    // The editor builds this with `zig build` and loads the result; its
    \\    // installed path is `game_library` in .fusion/fusion.proj.
    \\    const lib = b.addLibrary(.{
    \\        .name = "game",
    \\        .linkage = .dynamic,
    \\        .root_module = game_mod,
    \\    });
    \\    b.installArtifact(lib);
    \\
    \\    const tests = b.addTest(.{ .root_module = game_mod });
    \\    const run_tests = b.addRunArtifact(tests);
    \\    b.step("test", "Run game tests").dependOn(&run_tests.step);
    \\}
    \\
;

pub const root_zig =
    \\const sdk = @import("fusion_sdk");
    \\const game = @import("game.zig");
    \\
    \\comptime {
    \\    sdk.exportGame(&game.module);
    \\}
    \\
    \\test {
    \\    _ = @import("game.zig");
    \\}
    \\
;

/// The UUID of the sample component in `game_zig`, as the default scene references it.
pub const spin_component_id = "5b8f3c1e-2d4a-4f6b-9a7c-1e0d2c3b4a59";

pub const game_zig =
    \\//! Your game. The editor rebuilds and reloads this library when you press Play.
    \\
    \\const std = @import("std");
    \\const sdk = @import("fusion_sdk");
    \\
    \\const TransformComponent = sdk.components.TransformComponent;
    \\
    \\/// Turns its entity around the Y axis. Add it to an entity in the Inspector.
    \\pub const Spin = struct {
    \\    /// Radians per second.
    \\    speed: f32 = 1.0,
    \\
    \\    pub const schema_meta = sdk.scene_schema.SchemaMeta{
    \\        .id = "5b8f3c1e-2d4a-4f6b-9a7c-1e0d2c3b4a59",
    \\        .name = "game.spin",
    \\        .display_name = "Spin",
    \\        .version = 1,
    \\        .fields = &.{
    \\            .{ .name = "speed", .number = 1, .display_name = "Speed" },
    \\        },
    \\    };
    \\};
    \\
    \\pub const module = sdk.game(.{
    \\    .components = &.{Spin},
    \\    .start = start,
    \\    .update = update,
    \\});
    \\
    \\fn start(world: sdk.World) !void {
    \\    world.log(.info, "game started", .{});
    \\}
    \\
    \\fn update(world: sdk.World, frame: *const sdk.Frame) !void {
    \\    var spinners = try world.query(.{
    \\        .read = &.{Spin},
    \\        .write = &.{TransformComponent},
    \\    });
    \\
    \\    while (try spinners.each()) |row| {
    \\        const spin = try row.read(Spin);
    \\        var transform = try row.read(TransformComponent);
    \\        transform.rotation = spinStep(spin, frame.seconds).mul(transform.rotation);
    \\        try row.write(TransformComponent, transform);
    \\    }
    \\}
    \\
    \\fn spinStep(spin: Spin, seconds: f32) sdk.Quat {
    \\    return sdk.Quat.fromAxisAngle(sdk.Vec3.new(0, 1, 0), spin.speed * seconds);
    \\}
    \\
    \\test "a spin step turns by speed times elapsed time" {
    \\    const step = spinStep(.{ .speed = std.math.pi }, 0.5);
    \\    const turned = step.rotateVec3(sdk.Vec3.new(0, 0, -1));
    \\    try std.testing.expectApproxEqAbs(@as(f32, -1), turned.x, 0.0001);
    \\    try std.testing.expectApproxEqAbs(@as(f32, 0), turned.z, 0.0001);
    \\}
    \\
;

pub const gitignore =
    \\.zig-cache/
    \\zig-out/
    \\zig-pkg/
    \\
    \\.fusion/assets.zmanifest
    \\.fusion/.zcache
    \\.fusion/cooked/
    \\.fusion/game/
    \\
    \\assets/generated
    \\
;

/// `build.zig.zon` for a project at `project_root` (an absolute path).
/// `fingerprint_id` must be random and neither 0 nor 0xffffffff.
pub fn buildZigZon(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    sdk: SdkDependency,
    fingerprint_id: u32,
) ![]u8 {
    // Zig checks the upper half of a fingerprint against the package name.
    const fingerprint = (@as(u64, std.hash.Crc32.hash(package_name)) << 32) | fingerprint_id;

    const dependency = switch (sdk) {
        .remote => |remote| try std.fmt.allocPrint(
            allocator,
            "            .url = \"{s}\",\n            .hash = \"{s}\",\n",
            .{ remote.url, remote.hash },
        ),
        .path => |sdk_root| path: {
            const relative = try std.fs.path.relativeAlloc(allocator, "/", null, project_root, sdk_root);
            defer allocator.free(relative);
            break :path try std.fmt.allocPrint(allocator, "            .path = \"{s}\",\n", .{relative});
        },
    };
    defer allocator.free(dependency);

    return std.fmt.allocPrint(allocator,
        \\.{{
        \\    .name = .{s},
        \\    .version = "0.0.1",
        \\    .fingerprint = 0x{x:0>16},
        \\    .minimum_zig_version = "0.17.0",
        \\    .dependencies = .{{
        \\        .fusion_sdk = .{{
        \\{s}        }},
        \\    }},
        \\    .paths = .{{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "src",
        \\    }},
        \\}}
        \\
    , .{ package_name, fingerprint, dependency });
}

const testing = std.testing;

test "build.zig.zon pins a remote SDK by url and hash" {
    const zon = try buildZigZon(testing.allocator, "/work/game", .{ .remote = .{ .url = "git+https://example.com/sdk#abc", .hash = "sdk-1.0.0-hash" } }, 0x1234abcd);
    defer testing.allocator.free(zon);

    try testing.expect(std.mem.indexOf(u8, zon, ".name = .game,") != null);
    try testing.expect(std.mem.indexOf(u8, zon, ".url = \"git+https://example.com/sdk#abc\",") != null);
    try testing.expect(std.mem.indexOf(u8, zon, ".hash = \"sdk-1.0.0-hash\",") != null);
    try testing.expect(std.mem.indexOf(u8, zon, ".path = ") == null);

    // Low half is the random id, high half the CRC-32 of the package name.
    var expected: [64]u8 = undefined;
    const line = try std.fmt.bufPrint(&expected, ".fingerprint = 0x{x:0>8}1234abcd,", .{std.hash.Crc32.hash(package_name)});
    try testing.expect(std.mem.indexOf(u8, zon, line) != null);
}

test "build.zig.zon references a local SDK relative to the project" {
    const zon = try buildZigZon(testing.allocator, "/work/games/mine", .{ .path = "/work/fusion-sdk" }, 1);
    defer testing.allocator.free(zon);

    try testing.expect(std.mem.indexOf(u8, zon, ".path = \"../../fusion-sdk\",") != null);
    try testing.expect(std.mem.indexOf(u8, zon, ".url = ") == null);
}
