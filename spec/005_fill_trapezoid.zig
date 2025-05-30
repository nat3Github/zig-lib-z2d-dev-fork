// SPDX-License-Identifier: 0BSD
//   Copyright © 2024-2025 Chris Marchesi

//! Case: Renders and fills a trapezoid on a 300x300 surface.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "005_fill_trapezoid";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 300;
    const height = 300;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);

    const margin_top = 89;
    const margin_bottom = 50;
    const margin_y = 100;
    try context.moveTo(0 + margin_top, 0 + margin_y);
    try context.lineTo(width - margin_top - 1, 0 + margin_y);
    try context.lineTo(width - margin_bottom - 1, height - margin_y - 1);
    try context.lineTo(0 + margin_bottom, height - margin_y - 1);
    try context.closePath();

    try context.fill();

    return sfc;
}
