const fusion = @import("fusion_runtime");

const components = @import("../editor_components.zig");

const EditorPlayback = @This();

play_state: PlayState = .Stop,
/// The fly camera in the authoring world.
editor_camera: fusion.EntityID,

/// Everything that defines an editor camera's view, so one can be recreated
/// in another world looking at the same thing.
pub const CameraState = struct {
    transform: fusion.components.TransformComponent = .{},
    camera: fusion.components.CameraComponent = .{},
    controller: components.FlyCameraController = .{},
};

/// Spawns the editor camera in the authoring world, starting where the
/// scene's own camera is, and makes it the active one.
pub fn init(world: *fusion.EcsWorld) !EditorPlayback {
    var state: CameraState = .{};
    if (fusion.activeCamera(world)) |scene_camera| {
        state.transform = world.getComponent(scene_camera, fusion.components.TransformComponent).?.*;
        state.camera = world.getComponent(scene_camera, fusion.components.CameraComponent).?.*;
    }

    const editor_camera = try spawnCamera(world, state);
    errdefer world.despawn(editor_camera);
    try fusion.setActiveCamera(world, editor_camera);

    return .{ .editor_camera = editor_camera };
}

/// Spawns an editor camera without activating it.
pub fn spawnCamera(world: *fusion.EcsWorld, state: CameraState) !fusion.EntityID {
    return world.spawnWith(.{ state.transform, state.camera, state.controller });
}

/// Reads back the view of a camera made by `spawnCamera`.
pub fn cameraState(world: *fusion.EcsWorld, camera: fusion.EntityID) CameraState {
    return .{
        .transform = world.getComponent(camera, fusion.components.TransformComponent).?.*,
        .camera = world.getComponent(camera, fusion.components.CameraComponent).?.*,
        .controller = world.getComponent(camera, components.FlyCameraController).?.*,
    };
}

pub const PlayState = enum {
    Play,
    Pause,
    Stop,

    pub const Transition = struct {
        from: PlayState,
        to: PlayState,
    };

    pub fn transitionTo(current: PlayState, next: PlayState) ?Transition {
        if (next == current or (next == .Pause and current != .Play)) {
            return null;
        }

        return .{ .from = current, .to = next };
    }
};

const std = @import("std");
const testing = std.testing;

fn testWorld() !fusion.EcsWorld {
    var world = fusion.EcsWorld.init(testing.allocator);
    errdefer world.deinit();
    inline for (.{
        fusion.components.TransformComponent,
        fusion.components.CameraComponent,
        fusion.ActiveCamera,
        components.FlyCameraController,
    }) |Component| {
        _ = try world.registerType(Component, .{ .schema_hash = 0 });
    }
    return world;
}

test "the editor camera starts at the scene camera and becomes active" {
    var world = try testWorld();
    defer world.deinit();
    const scene_camera = try world.spawnWith(.{
        fusion.components.TransformComponent{ .position = fusion.Vec3.new(1, 2, 3) },
        fusion.components.CameraComponent{ .fov = 0.5 },
    });
    try fusion.setActiveCamera(&world, scene_camera);

    const playback = try EditorPlayback.init(&world);
    try testing.expectEqual(PlayState.Stop, playback.play_state);
    try testing.expect(!playback.editor_camera.eql(scene_camera));
    try testing.expectEqual(playback.editor_camera, fusion.activeCamera(&world).?);

    const state = cameraState(&world, playback.editor_camera);
    try testing.expectEqual(@as(f32, 2), state.transform.position.y);
    try testing.expectEqual(@as(f32, 0.5), state.camera.fov);
}

test "an editor camera can be recreated in another world with the same view" {
    var first = try testWorld();
    defer first.deinit();
    var second = try testWorld();
    defer second.deinit();

    // A scene without a camera still gets a default editor camera.
    const playback = try EditorPlayback.init(&first);
    const controller = first.getComponent(playback.editor_camera, components.FlyCameraController).?;
    controller.yaw = 1.25;
    first.getComponent(playback.editor_camera, fusion.components.TransformComponent).?.position.x = 9;

    const copy = try spawnCamera(&second, cameraState(&first, playback.editor_camera));
    try testing.expect(fusion.activeCamera(&second) == null);
    const state = cameraState(&second, copy);
    try testing.expectEqual(@as(f32, 9), state.transform.position.x);
    try testing.expectEqual(@as(f32, 1.25), state.controller.yaw);
}

test "play state accepts only meaningful transitions" {
    try testing.expectEqual(PlayState.Play, PlayState.Stop.transitionTo(.Play).?.to);
    try testing.expectEqual(PlayState.Pause, PlayState.Play.transitionTo(.Pause).?.to);
    try testing.expectEqual(PlayState.Stop, PlayState.Pause.transitionTo(.Stop).?.to);
    try testing.expect(PlayState.Stop.transitionTo(.Pause) == null);
    try testing.expect(PlayState.Stop.transitionTo(.Stop) == null);
}

test "pause is only meaningful while playing" {
    try testing.expect(PlayState.Pause.transitionTo(.Pause) == null);
    try testing.expect(PlayState.Stop.transitionTo(.Pause) == null);
}

test "play and stop are idempotent from their own state" {
    try testing.expect(PlayState.Play.transitionTo(.Play) == null);
    try testing.expect(PlayState.Stop.transitionTo(.Stop) == null);
}

test "play resumes playback from a paused state" {
    const transition = PlayState.Pause.transitionTo(.Play).?;
    try testing.expectEqual(PlayState.Pause, transition.from);
    try testing.expectEqual(PlayState.Play, transition.to);
}

test "stop is always reachable from play or pause" {
    try testing.expectEqual(PlayState.Stop, PlayState.Play.transitionTo(.Stop).?.to);
    try testing.expectEqual(PlayState.Stop, PlayState.Pause.transitionTo(.Stop).?.to);
}
