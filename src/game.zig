const editor_components = @import("editor_components.zig");
const editor_camera = @import("editor_camera.zig");
const fusion = @import("fusion_runtime");

pub const definition = fusion.Game{
    .components = &.{
        editor_components.FlyCameraController,
    },
    .fixed_update_schedule = .{
        .update = &.{
            fusion.game_module.fixedUpdate,
        },
    },
};

pub const editor_schedule_override = fusion.Schedule.Spec{
    .update = &.{
        editor_camera.updateActiveSystem,
    },
};
