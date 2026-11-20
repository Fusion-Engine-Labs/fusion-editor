const fusion = @import("fusion_runtime");
const zimp = @import("zimp");
const std = @import("std");

const SceneMutation = @import("scene_mutation.zig").Mutation;
const SceneInputCapture = @import("../ui/scene_input.zig");
const EditorPlayback = @import("../state/play_state.zig");
const ProjectModel = @import("project_model.zig");
const log = @import("../utilities/log.zig");
const GameCode = @import("game_code.zig");
const Game = @import("../game.zig");

const Runtime = fusion.Runtime(Game.definition);
const GameLibrary = fusion.game_module.GameLibrary;

const SceneController = @This();

const ActiveScene = struct {
    file_name: []const u8,
    dirty: bool,
};

/// The cameras of the running play session. Both live in the play world.
const PlayCameras = struct {
    /// What the game renders through; restored when resuming from pause.
    scene: fusion.EntityID,
    /// A fly camera for looking around while paused.
    editor: fusion.EntityID,
};

project: *ProjectModel,
runtime: *Runtime,
game: *GameCode,
playback: EditorPlayback,
play_cameras: ?PlayCameras = null,
/// Play was pressed and is waiting for the game build to finish.
play_when_built: bool = false,
input_capture: SceneInputCapture = .{},
active_scene: ?ActiveScene = null,
selected_entity: ?fusion.SceneEntityId = null,
revision_number: u64 = 0,

pub fn init(project: *ProjectModel, runtime: *Runtime, game: *GameCode) !SceneController {
    var controller = SceneController{
        .project = project,
        .runtime = runtime,
        .game = game,
        .playback = try preparePlayback(runtime),
    };

    if (project.project.manifest.default_scene) |scene| {
        controller.active_scene = .{
            .file_name = scene,
            .dirty = false,
        };
    }

    return controller;
}

pub fn preparePlayback(runtime: *Runtime) !EditorPlayback {
    return EditorPlayback.init(&runtime.authoring.world.world);
}

/// Points the controller at another project's runtime. Call `shutdownPlay`
/// on the old one first.
pub fn rebind(self: *SceneController, runtime: *Runtime, playback: EditorPlayback) void {
    self.runtime = runtime;
    self.playback = playback;
    self.play_cameras = null;
    self.play_when_built = false;
    self.input_capture.reset();
    self.selected_entity = null;
    self.active_scene = if (self.project.project.manifest.default_scene) |scene|
        .{ .file_name = scene, .dirty = false }
    else
        null;
    self.revision_number +%= 1;
}

fn authoringWorld(self: *SceneController) *fusion.EcsWorld {
    return &self.runtime.authoring.world.world;
}

pub fn openScene(self: *SceneController, path: []const u8) !void {
    const document = try self.project.loadScene(path);

    // A play session belongs to the scene it was started from.
    self.shutdownPlay();

    deactivateEditorCamera(self.authoringWorld(), self.playback.editor_camera) catch |err| {
        var unused = document;
        unused.deinit();
        return err;
    };
    // Takes ownership of the document, including when it fails.
    try self.runtime.authoring.loadScene(&self.runtime.assets, document);
    try fusion.setActiveCamera(self.authoringWorld(), self.playback.editor_camera);

    self.selected_entity = null;
    self.revision_number +%= 1;
    self.active_scene = .{
        .file_name = path,
        .dirty = false,
    };
}

pub fn saveScene(self: *SceneController) !void {
    const active_scene = self.activeDocument() orelse return error.NoActiveScene;
    if (self.active_scene) |*scene| {
        if (scene.dirty) {
            try self.project.saveScene(scene.file_name, &active_scene.document);
            scene.dirty = false;
        }
    }
}

pub fn markDirty(self: *SceneController) void {
    if (self.active_scene) |*scene| {
        scene.dirty = true;
    }
}

pub fn isDirty(self: *const SceneController) bool {
    if (self.active_scene) |scene| {
        return scene.dirty;
    }

    return false;
}

/// The scene being authored. Edits made while playing change this document,
/// not the running game; they take effect the next time Play starts.
pub fn activeDocument(self: *SceneController) ?*fusion.scene_schema.LoadedScene {
    return @constCast(self.runtime.authoring.world.activeSceneDocument());
}

pub fn componentSchema(self: *const SceneController, id: fusion.ComponentTypeId) ?*const zimp.scene.ComponentSchema {
    const codec = self.runtime.authoring.schemas.get(id) orelse return null;
    return &codec.schema;
}

pub fn commitSceneMutation(self: *SceneController, mutation: SceneMutation) !void {
    const active_scene = self.activeDocument();
    if (active_scene) |scene| {
        mutation.apply(scene) catch |err| {
            // A mutation writes the document before it updates the world, so
            // a failure may still have changed what will be saved.
            self.markDirty();
            self.revision_number +%= 1;
            return err;
        };
        if (self.selected_entity) |selected| {
            if (scene.document.entityIndex(selected) == null) {
                self.selected_entity = null;
            }
        }
        self.markDirty();
        self.revision_number +%= 1;
    }
}

pub fn selectEntity(self: *SceneController, entity: ?fusion.SceneEntityId) void {
    if (optionalEntityEql(self.selected_entity, entity)) {
        return;
    }
    self.selected_entity = entity;
    self.revision_number +%= 1;
}

pub fn selectedEntity(self: *const SceneController) ?fusion.SceneEntityId {
    return self.selected_entity;
}

pub fn revision(self: *const SceneController) u64 {
    return self.revision_number;
}

pub fn playState(self: *const SceneController) EditorPlayback.PlayState {
    return self.playback.play_state;
}

pub fn sceneInputCapture(self: *SceneController) *SceneInputCapture {
    return &self.input_capture;
}

/// From stopped: builds the game if the project has one, then starts a
/// fresh session. From paused: resumes the same session without building.
pub fn play(self: *SceneController) !void {
    switch (self.playback.play_state) {
        .Play => {},
        .Pause => try self.resumeSession(),
        .Stop => {
            if (!self.game.hasPackage()) {
                return self.startSession();
            }
            if (!self.game.isBuilding()) {
                try self.game.requestBuild();
            }
            self.play_when_built = true;
            self.revision_number +%= 1;
        },
    }
}

pub fn pause(self: *SceneController) !void {
    if (self.playback.play_state == .Play) {
        try self.pauseSession();
    }
}

/// Destroys the play session and forgets a Play that was waiting on a build.
pub fn stop(self: *SceneController) !void {
    if (self.play_when_built) {
        self.play_when_built = false;
        self.revision_number +%= 1;
    }
    if (self.playback.play_state != .Stop) {
        self.endSession();
    }
}

/// Builds the game. When the build lands, a running session restarts on
/// the new code; otherwise only the editor's component list is refreshed.
pub fn build(self: *SceneController) !void {
    try self.game.requestBuild();
    self.revision_number +%= 1;
}

pub fn canPlay(self: *SceneController) bool {
    return self.playback.play_state != .Play and !self.play_when_built;
}

pub fn canPause(self: *SceneController) bool {
    return self.playback.play_state == .Play;
}

pub fn canStop(self: *SceneController) bool {
    return self.playback.play_state != .Stop or self.play_when_built;
}

pub fn canBuild(self: *SceneController) bool {
    return self.game.hasPackage() and !self.game.isBuilding();
}

pub fn isBuilding(self: *const SceneController) bool {
    return self.game.isBuilding();
}

/// Ends the session and abandons any running build. For closing a scene or
/// project; afterwards nothing here refers to the game library.
pub fn shutdownPlay(self: *SceneController) void {
    self.play_when_built = false;
    self.game.cancelBuild();
    if (self.playback.play_state != .Stop) {
        self.endSession();
    }
}

/// Call once per frame: picks up a finished game build.
pub fn update(self: *SceneController) !void {
    switch (self.game.poll()) {
        .idle, .building => {},
        .failed => {
            self.play_when_built = false;
            self.revision_number +%= 1;
        },
        .built => |library| try self.installLibrary(library),
    }
}

/// Call when a frame of the play session failed: the session cannot continue.
pub fn failSession(self: *SceneController, err: anyerror) void {
    log.err("game update failed, stopping: {s}", .{@errorName(err)});
    self.endSession();
}

/// Switches the editor, and a running or requested session, to a newly
/// built library. On rejection everything keeps running on the previous one.
fn installLibrary(self: *SceneController, library: *const GameLibrary) !void {
    const restart = self.play_when_built or self.playback.play_state != .Stop;
    self.play_when_built = false;
    self.revision_number +%= 1;

    if (!try self.reloadAuthoring(library)) {
        self.game.discard(library);
        return;
    }

    if (restart) {
        self.startSession() catch |err| {
            log.err("game failed to start: {s}", .{@errorName(err)});
            // A session still running the previous library must end before
            // that library is closed below.
            self.endSession();
        };
    }
    self.game.install(library);
}

/// Rebuilds the authoring world around `library`'s components, keeping the
/// open scene and the editor camera's view. Returns false, with everything
/// left as it was, if the library is rejected.
fn reloadAuthoring(self: *SceneController, library: ?*const GameLibrary) !bool {
    const view = EditorPlayback.cameraState(self.authoringWorld(), self.playback.editor_camera);
    self.runtime.setGameLibrary(library) catch |err| {
        log.err("new game library was rejected, keeping the previous one: {s}", .{@errorName(err)});
        return false;
    };

    // The rebuild replaced the world, and the editor camera with it.
    self.playback.editor_camera = try EditorPlayback.spawnCamera(self.authoringWorld(), view);
    try fusion.setActiveCamera(self.authoringWorld(), self.playback.editor_camera);
    return true;
}

/// Starts a session from the current authoring scene, replacing a running
/// one only once the new one has started.
fn startSession(self: *SceneController) !void {
    const view = EditorPlayback.cameraState(self.authoringWorld(), self.playback.editor_camera);
    try self.runtime.beginPlay();
    errdefer self.endSession();

    const world = &self.runtime.play.?.world.world;
    const scene_camera = fusion.activeCamera(world);
    const editor_camera = try EditorPlayback.spawnCamera(world, view);
    if (scene_camera == null) {
        log.warn("the scene has no active camera; playing through the editor camera", .{});
        try fusion.setActiveCamera(world, editor_camera);
    }

    self.play_cameras = .{ .scene = scene_camera orelse editor_camera, .editor = editor_camera };
    self.playback.play_state = .Play;
    self.resetInput();
    self.revision_number +%= 1;
}

fn pauseSession(self: *SceneController) !void {
    const cameras = &(self.play_cameras orelse return);
    const world = &self.runtime.play.?.world.world;

    // The game may have switched cameras since the session started.
    cameras.scene = fusion.activeCamera(world) orelse cameras.editor;
    try fusion.setActiveCamera(world, cameras.editor);

    self.playback.play_state = .Pause;
    self.resetInput();
    self.revision_number +%= 1;
}

fn resumeSession(self: *SceneController) !void {
    const cameras = self.play_cameras orelse return;
    const world = &self.runtime.play.?.world.world;

    fusion.setActiveCamera(world, cameras.scene) catch |err| {
        log.warn("the game's camera is gone ({s}); staying on the editor camera", .{@errorName(err)});
    };

    self.playback.play_state = .Play;
    self.resetInput();
    self.revision_number +%= 1;
}

fn endSession(self: *SceneController) void {
    self.runtime.endPlay();
    self.play_cameras = null;
    self.playback.play_state = .Stop;
    self.resetInput();
    self.revision_number +%= 1;
}

fn resetInput(self: *SceneController) void {
    self.runtime.input().clear();
    self.input_capture.reset();
}

fn optionalEntityEql(a: ?fusion.SceneEntityId, b: ?fusion.SceneEntityId) bool {
    if (a) |left| {
        if (b) |right| {
            return left.eql(right);
        }
        return false;
    }
    return b == null;
}

fn deactivateEditorCamera(world: *fusion.EcsWorld, editor_camera: fusion.EntityID) !void {
    if (world.hasComponent(editor_camera, fusion.ActiveCamera)) {
        try world.removeComponent(editor_camera, fusion.ActiveCamera);
    }
}

const testing = std.testing;
const TransformComponent = fusion.components.TransformComponent;
const CameraComponent = fusion.components.CameraComponent;

test "opening a scene removes the persistent editor camera active marker" {
    var world = fusion.EcsWorld.init(testing.allocator);
    defer world.deinit();
    inline for (.{ TransformComponent, CameraComponent, fusion.ActiveCamera }) |Component| {
        _ = try world.registerType(Component, .{ .schema_hash = 0 });
    }

    const editor_camera = try world.spawnWith(.{
        TransformComponent{},
        CameraComponent{},
    });
    const scene_camera = try world.spawnWith(.{
        TransformComponent{},
        CameraComponent{},
    });
    try fusion.setActiveCamera(&world, editor_camera);

    // Scene deserialization can add this marker directly, before the editor
    // gets the chance to switch active cameras back to its own camera.
    try world.addComponent(scene_camera, fusion.ActiveCamera, .{});
    try deactivateEditorCamera(&world, editor_camera);

    try testing.expect(!world.hasComponent(editor_camera, fusion.ActiveCamera));
    try testing.expectEqual(scene_camera, fusion.activeCamera(&world).?);
}

/// A project on disk plus the CPU-side runtime services, assembled without
/// a window or GL context, with a controller on top.
const TestRig = struct {
    tmp: testing.TmpDir,
    project: fusion.Project,
    runtime: Runtime,
    model: ProjectModel,
    game: GameCode,
    controller: SceneController,

    const scene_id = fusion.SceneId.parseComptime("3b1d9f60-7c2a-4e58-a1f4-6d0e9c8b7a21");
    const camera_id = fusion.SceneEntityId.parseComptime("a4c8e2f1-5b3d-4a69-8c7e-1f2d3b4a5c6e");
    const prop_id = fusion.SceneEntityId.parseComptime("d7e1f3a5-9b2c-4d6e-8f0a-2c4e6a8b0d1f");
    const transform_type = fusion.ComponentTypeId.parseComptime(TransformComponent.schema_meta.id);
    const camera_type = fusion.ComponentTypeId.parseComptime(CameraComponent.schema_meta.id);
    const active_camera_type = fusion.ComponentTypeId.parseComptime(fusion.ActiveCamera.schema_meta.id);

    /// Initialized in place: the parts point at each other.
    fn init(self: *TestRig, with_scene_camera: bool) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        try self.tmp.dir.createDirPath(testing.io, ".fusion/cooked");
        var manifest = try zimp.manifest.model.testManifest(testing.allocator, &.{});
        defer manifest.deinit();
        try zimp.manifest.codec.writeToDir(testing.allocator, testing.io, self.tmp.dir, ".fusion/assets.zmanifest", &manifest);
        self.project = .{ .root_dir = self.tmp.dir, .manifest = .{ .project_id = .zero } };

        self.runtime = .{
            .allocator = testing.allocator,
            .io = testing.io,
            .project = &self.project,
            .authoring = undefined,
            .assets = undefined,
            .renderer = undefined,
            .time = try fusion.Time.init(Game.definition.simulation),
        };
        self.runtime.renderer = try fusion.Renderer.init(testing.allocator, .opengl);
        errdefer self.runtime.renderer.deinit();
        self.runtime.assets = try fusion.AssetManager.init(testing.allocator, testing.io, &self.project, &self.runtime.renderer.device);
        errdefer self.runtime.assets.deinit();
        self.runtime.authoring = try fusion.Session.create(testing.allocator, Game.definition, .{});
        errdefer self.runtime.authoring.destroy();
        try self.runtime.authoring.loadScene(&self.runtime.assets, try testScene(with_scene_camera));

        self.model = ProjectModel.init(testing.allocator, testing.io, &self.project);
        self.game = GameCode.init(testing.allocator, testing.io, &self.project);
        self.controller = try SceneController.init(&self.model, &self.runtime, &self.game);
    }

    fn deinit(self: *TestRig) void {
        self.controller.shutdownPlay();
        self.game.deinit();
        self.runtime.assets.deinit();
        self.runtime.renderer.deinit();
        self.runtime.authoring.destroy();
        self.tmp.cleanup();
    }

    fn testScene(with_scene_camera: bool) !zimp.scene.SceneDocument {
        var document = try zimp.scene.SceneDocument.init(testing.allocator, scene_id, .zero, "Controller Test");
        errdefer document.deinit();
        const arena = document.arena.allocator();

        const camera_components = try arena.alloc(zimp.scene.SceneComponent, 3);
        camera_components[0] = .{ .type_id = transform_type, .fields = &.{} };
        camera_components[1] = .{ .type_id = camera_type, .fields = &.{} };
        camera_components[2] = .{ .type_id = active_camera_type, .fields = &.{} };
        const prop_components = try arena.alloc(zimp.scene.SceneComponent, 1);
        prop_components[0] = .{ .type_id = transform_type, .fields = &.{} };

        document.entities = try arena.alloc(zimp.scene.SceneEntity, 2);
        document.entities[0] = .{
            .id = camera_id,
            .name = "Camera",
            .components = if (with_scene_camera) camera_components else camera_components[0..1],
            .prefab = .{},
        };
        document.entities[1] = .{ .id = prop_id, .name = "Prop", .components = prop_components, .prefab = .{} };
        return document;
    }

    fn countTransforms(session: *fusion.Session) usize {
        var count: usize = 0;
        var query = session.world.world.query(.{ .read = &.{TransformComponent} });
        while (query.each()) |_| count += 1;
        return count;
    }
};

test "play, pause, resume and stop drive a disposable session and its cameras" {
    var rig: TestRig = undefined;
    try rig.init(true);
    defer rig.deinit();
    const controller = &rig.controller;
    const runtime = &rig.runtime;

    // Authoring: two scene entities plus the editor camera, which is active.
    try testing.expectEqual(@as(usize, 3), TestRig.countTransforms(runtime.authoring));
    try testing.expectEqual(controller.playback.editor_camera, fusion.activeCamera(controller.authoringWorld()).?);
    try testing.expect(controller.canPlay());
    try testing.expect(!controller.canPause());
    try testing.expect(!controller.canStop());
    try testing.expect(!controller.canBuild());

    // No game package, so Play starts immediately.
    try controller.play();
    try testing.expectEqual(EditorPlayback.PlayState.Play, controller.playState());
    try testing.expect(runtime.isPlaying());
    const play_world = &runtime.play.?.world.world;
    const cameras = controller.play_cameras.?;
    try testing.expectEqual(@as(usize, 3), TestRig.countTransforms(runtime.play.?));
    try testing.expect(!cameras.scene.eql(cameras.editor));
    try testing.expectEqual(cameras.scene, fusion.activeCamera(play_world).?);
    try testing.expect(!controller.canPlay());

    // Something the game would create exists only in the play world.
    _ = try play_world.spawnWith(.{TransformComponent{}});
    try testing.expectEqual(@as(usize, 4), TestRig.countTransforms(runtime.play.?));
    try testing.expectEqual(@as(usize, 3), TestRig.countTransforms(runtime.authoring));

    try controller.pause();
    try testing.expectEqual(EditorPlayback.PlayState.Pause, controller.playState());
    try testing.expectEqual(cameras.editor, fusion.activeCamera(play_world).?);
    try testing.expect(controller.canPlay());

    // Resuming keeps the same world: the extra entity is still there.
    const session = runtime.play.?;
    try controller.play();
    try testing.expectEqual(EditorPlayback.PlayState.Play, controller.playState());
    try testing.expectEqual(session, runtime.play.?);
    try testing.expectEqual(cameras.scene, fusion.activeCamera(play_world).?);
    try testing.expectEqual(@as(usize, 4), TestRig.countTransforms(runtime.play.?));

    try controller.stop();
    try testing.expectEqual(EditorPlayback.PlayState.Stop, controller.playState());
    try testing.expect(!runtime.isPlaying());
    try testing.expect(controller.play_cameras == null);
    try testing.expectEqual(@as(usize, 3), TestRig.countTransforms(runtime.authoring));
    try testing.expectEqual(controller.playback.editor_camera, fusion.activeCamera(controller.authoringWorld()).?);

    // Playing again starts from the authored scene, not the last session.
    try controller.play();
    try testing.expectEqual(@as(usize, 3), TestRig.countTransforms(runtime.play.?));
    controller.failSession(error.TestFailure);
    try testing.expectEqual(EditorPlayback.PlayState.Stop, controller.playState());
    try testing.expect(!runtime.isPlaying());
}

test "a scene without a camera plays through the editor camera" {
    var rig: TestRig = undefined;
    try rig.init(false);
    defer rig.deinit();
    const controller = &rig.controller;

    try controller.play();
    const cameras = controller.play_cameras.?;
    try testing.expect(cameras.scene.eql(cameras.editor));
    try testing.expectEqual(cameras.editor, fusion.activeCamera(&rig.runtime.play.?.world.world).?);

    try controller.pause();
    try controller.play();
    try testing.expectEqual(cameras.editor, fusion.activeCamera(&rig.runtime.play.?.world.world).?);
}

test "reloading the authoring world keeps the scene and editor view and leaves play alone" {
    var rig: TestRig = undefined;
    try rig.init(true);
    defer rig.deinit();
    const controller = &rig.controller;
    const runtime = &rig.runtime;

    controller.authoringWorld().getComponent(controller.playback.editor_camera, TransformComponent).?.position.x = 12;
    // Not part of the document, so a rebuilt world will not have it.
    _ = try controller.authoringWorld().spawnWith(.{TransformComponent{}});
    try testing.expectEqual(@as(usize, 4), TestRig.countTransforms(runtime.authoring));

    try controller.play();
    const session = runtime.play.?;
    _ = try session.world.world.spawnWith(.{TransformComponent{}});

    // The path a finished build takes, minus the library hand-over.
    try testing.expect(try controller.reloadAuthoring(null));
    try testing.expectEqual(@as(usize, 3), TestRig.countTransforms(runtime.authoring));
    try testing.expectEqual(controller.playback.editor_camera, fusion.activeCamera(controller.authoringWorld()).?);
    try testing.expectEqual(@as(f32, 12), controller.authoringWorld().getComponent(controller.playback.editor_camera, TransformComponent).?.position.x);
    try testing.expectEqual(session, runtime.play.?);
    try testing.expectEqual(@as(usize, 4), TestRig.countTransforms(runtime.play.?));

    // Restarting replaces the session with a fresh copy of the scene, and
    // its paused view starts where the editor camera is.
    try controller.startSession();
    try testing.expectEqual(EditorPlayback.PlayState.Play, controller.playState());
    try testing.expectEqual(@as(usize, 3), TestRig.countTransforms(runtime.play.?));
    const paused_view = runtime.play.?.world.world.getComponent(controller.play_cameras.?.editor, TransformComponent).?;
    try testing.expectEqual(@as(f32, 12), paused_view.position.x);
}
