//! Case: Renders and strokes stars on a 900x300 surface with rounded corners,
//! and varying tolerance.
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "030_stroke_star_round_tolerance";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 900;
    const height = 300;
    const sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context: z2d.Context = .{
        .surface = sfc,
        .pattern = .{
            .opaque_pattern = .{
                .pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }, // White on black
            },
        },
        .line_width = 30,
        .line_join_mode = .round,
        .anti_aliasing_mode = aa_mode,
    };

    var path = z2d.Path.init(alloc);
    defer path.deinit();

    const margin = 20;
    const sub_canvas_width = 300;
    const x_scale = 3;
    const y_scale = 5;
    // With all 5 points numbered 1-5 clockwise, we draw odds first (1, 3, 5),
    // then evens (4, 2), with the close connecting 4 and 1.
    try path.moveTo(sub_canvas_width / 2, 0 + margin); // 1
    try path.lineTo(sub_canvas_width - margin * x_scale - 1, height - margin - 1); // 3
    try path.lineTo(0 + margin, 0 + margin * y_scale); // 5
    try path.lineTo(sub_canvas_width - margin - 1, 0 + margin * y_scale); // 2
    try path.lineTo(0 + margin * x_scale, height - margin - 1); // 4
    try path.close();
    try context.stroke(alloc, path);

    path.reset();
    context.tolerance = 3;
    var x_offset: f64 = 300;
    try path.moveTo(x_offset + sub_canvas_width / 2, 0 + margin); // 1
    try path.lineTo(x_offset + sub_canvas_width - margin * x_scale - 1, height - margin - 1); // 3
    try path.lineTo(x_offset + 0 + margin, 0 + margin * y_scale); // 5
    try path.lineTo(x_offset + sub_canvas_width - margin - 1, 0 + margin * y_scale); // 2
    try path.lineTo(x_offset + 0 + margin * x_scale, height - margin - 1); // 4
    try path.close();
    try context.stroke(alloc, path);

    path.reset();
    context.tolerance = 10;
    x_offset = 600;
    try path.moveTo(x_offset + sub_canvas_width / 2, 0 + margin); // 1
    try path.lineTo(x_offset + sub_canvas_width - margin * x_scale - 1, height - margin - 1); // 3
    try path.lineTo(x_offset + 0 + margin, 0 + margin * y_scale); // 5
    try path.lineTo(x_offset + sub_canvas_width - margin - 1, 0 + margin * y_scale); // 2
    try path.lineTo(x_offset + 0 + margin * x_scale, height - margin - 1); // 4
    try path.close();
    try context.stroke(alloc, path);

    return sfc;
}
