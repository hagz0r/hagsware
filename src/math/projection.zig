const Vec2 = @import("../utils/types.zig").Vec2;
const Vec3 = @import("../utils/types.zig").Vec3;

pub const Mat4x4 = [4][4]f32;

pub fn worldToScreen(origin: Vec3, matrix: Mat4x4, screen_width: f32, screen_height: f32) ?Vec2 {
    const clip_x =
        matrix[0][0] * origin.x +
        matrix[0][1] * origin.y +
        matrix[0][2] * origin.z +
        matrix[0][3];
    const clip_y =
        matrix[1][0] * origin.x +
        matrix[1][1] * origin.y +
        matrix[1][2] * origin.z +
        matrix[1][3];
    const clip_w =
        matrix[3][0] * origin.x +
        matrix[3][1] * origin.y +
        matrix[3][2] * origin.z +
        matrix[3][3];
    if (clip_w <= 0.001) return null;

    const inv_w: f32 = 1.0 / clip_w;
    const ndc_x = clip_x * inv_w;
    const ndc_y = clip_y * inv_w;
    if (ndc_x < -1.0 or ndc_x > 1.0 or ndc_y < -1.0 or ndc_y > 1.0) return null;

    return .{
        .x = (screen_width * 0.5) * (ndc_x + 1.0),
        .y = (screen_height * 0.5) * (1.0 - ndc_y),
    };
}
