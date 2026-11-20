const fusion = @import("fusion_runtime");
const zimp = @import("zimp");
const std = @import("std");

const log = @import("../utilities/log.zig");

pub const template = @import("project_template.zig");

pub const CreateOptions = struct {
    name: []const u8,
    sdk: template.SdkDependency = template.default_sdk,
};

const transform_type_id = fusion.ComponentTypeId.parseComptime(fusion.components.TransformComponent.schema_meta.id);
const camera_type_id = fusion.ComponentTypeId.parseComptime(fusion.components.CameraComponent.schema_meta.id);
const active_camera_type_id = fusion.ComponentTypeId.parseComptime(fusion.components.ActiveCamera.schema_meta.id);
const spin_type_id = fusion.ComponentTypeId.parseComptime(template.spin_component_id);

/// Turns the existing directory at `root_path` (absolute) into a project that
/// opens and plays as-is: a manifest, a default scene, and a game package.
pub fn createProject(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    options: CreateOptions,
) !void {
    var root_dir = try std.Io.Dir.openDirAbsolute(io, root_path, .{});
    defer root_dir.close(io);

    if (root_dir.access(io, zimp.project.manifest.default_manifest_path, .{})) |_| {
        return error.ProjectAlreadyExists;
    } else |_| {}

    const random_source: std.Random.IoSource = .{ .io = io };
    const random = random_source.interface();

    const manifest = zimp.ProjectManifest{
        .project_id = .v4(random),
        .name = options.name,
        .default_scene = template.default_scene_path,
        .game_library = template.game_library_path,
    };

    try root_dir.createDirPath(io, manifest.generated_dir);
    try root_dir.createDirPath(io, manifest.assets_dir);
    try root_dir.createDirPath(io, manifest.scenes_dir);
    try root_dir.createDirPath(io, manifest.cooked_assets_dir);
    try root_dir.createDirPath(io, "src");

    try writeDefaultScene(allocator, io, root_dir, &manifest, random);

    const zon = try template.buildZigZon(allocator, root_path, options.sdk, random.intRangeLessThan(u32, 1, 0xffffffff));
    defer allocator.free(zon);
    try root_dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = zon });
    try root_dir.writeFile(io, .{ .sub_path = "build.zig", .data = template.build_zig });
    try root_dir.writeFile(io, .{ .sub_path = "src/root.zig", .data = template.root_zig });
    try root_dir.writeFile(io, .{ .sub_path = "src/game.zig", .data = template.game_zig });
    try root_dir.writeFile(io, .{ .sub_path = ".gitignore", .data = template.gitignore });

    // Last, so a half-written directory is never mistaken for a project.
    try manifest.save(allocator, io, root_dir);

    log.info("Created project at {s}", .{root_path});
}

/// A camera looking at the origin and an entity that uses the sample game
/// component, so the first Play shows game code running.
fn writeDefaultScene(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    manifest: *const zimp.ProjectManifest,
    random: std.Random,
) !void {
    var document = try zimp.scene.SceneDocument.init(allocator, .v4(random), manifest.project_id, "Main");
    defer document.deinit();
    const arena = document.arena.allocator();

    const camera_position = try arena.alloc(zimp.scene.SceneField, 1);
    camera_position[0] = .{ .number = 1, .value = .{ .vec3 = .{ 0, 0, 3 } } };
    const camera_components = try arena.alloc(zimp.scene.SceneComponent, 3);
    camera_components[0] = .{ .type_id = transform_type_id, .fields = camera_position };
    camera_components[1] = .{ .type_id = camera_type_id, .fields = &.{} };
    camera_components[2] = .{ .type_id = active_camera_type_id, .fields = &.{} };

    const spinner_components = try arena.alloc(zimp.scene.SceneComponent, 2);
    spinner_components[0] = .{ .type_id = transform_type_id, .fields = &.{} };
    spinner_components[1] = .{ .type_id = spin_type_id, .fields = &.{} };

    document.entities = try arena.alloc(zimp.scene.SceneEntity, 2);
    document.entities[0] = .{ .id = .v4(random), .name = "Camera", .components = camera_components, .prefab = .{} };
    document.entities[1] = .{ .id = .v4(random), .name = "Spinner", .components = spinner_components, .prefab = .{} };

    try document.write(allocator, io, root_dir, template.default_scene_path, .{
        .project_id = manifest.project_id,
        .format = .json,
    });
}

const testing = std.testing;

fn tmpRootPath(tmp: *testing.TmpDir, buffer: *[std.Io.Dir.max_path_bytes]u8) ![]const u8 {
    const len = try tmp.dir.realPathFile(testing.io, ".", buffer);
    return buffer[0..len];
}

fn findEntity(scene: *const zimp.scene.SceneDocument, name: []const u8) ?*const zimp.scene.SceneEntity {
    for (scene.entities) |*entity| {
        if (std.mem.eql(u8, entity.name, name)) return entity;
    }
    return null;
}

test "createProject writes a project that opens with a default scene and a game package" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = try tmpRootPath(&tmp, &buffer);

    try createProject(testing.allocator, testing.io, root_path, .{ .name = "Scaffold Test" });

    var project = try fusion.openProject(testing.allocator, testing.io, .{ .root_path = root_path });
    defer project.deinit(testing.allocator, testing.io);
    try testing.expectEqualStrings("Scaffold Test", project.manifest.name);
    try testing.expectEqualStrings(template.default_scene_path, project.manifest.default_scene.?);
    try testing.expectEqualStrings(template.game_library_path, project.manifest.game_library.?);

    var scene = try project.loadDefaultScene(testing.allocator, testing.io);
    defer scene.deinit();
    try testing.expectEqual(@as(usize, 2), scene.entities.len);
    // Saved scenes order entities by id, and these ids are random.
    const camera = findEntity(&scene, "Camera") orelse return error.MissingCamera;
    const spinner = findEntity(&scene, "Spinner") orelse return error.MissingSpinner;
    try testing.expect(camera.componentIndex(active_camera_type_id) != null);
    try testing.expect(camera.componentIndex(camera_type_id) != null);
    const camera_transform = camera.components[camera.componentIndex(transform_type_id).?];
    try testing.expectEqual([3]f32{ 0, 0, 3 }, camera_transform.fields[0].value.vec3);
    try testing.expect(spinner.componentIndex(spin_type_id) != null);
    try testing.expect(!camera.id.eql(spinner.id));

    inline for (.{ "build.zig", "build.zig.zon", "src/root.zig", "src/game.zig", ".gitignore", "assets", ".fusion/cooked" }) |path| {
        try tmp.dir.access(testing.io, path, .{});
    }
    const game_source = try tmp.dir.readFileAlloc(testing.io, "src/game.zig", testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(game_source);
    try testing.expect(std.mem.indexOf(u8, game_source, template.spin_component_id) != null);
}

test "createProject refuses to overwrite an existing project" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = try tmpRootPath(&tmp, &buffer);

    try createProject(testing.allocator, testing.io, root_path, .{ .name = "First" });
    try testing.expectError(error.ProjectAlreadyExists, createProject(testing.allocator, testing.io, root_path, .{ .name = "Second" }));

    var project = try fusion.openProject(testing.allocator, testing.io, .{ .root_path = root_path });
    defer project.deinit(testing.allocator, testing.io);
    try testing.expectEqualStrings("First", project.manifest.name);
}

test {
    _ = @import("project_template.zig");
}
