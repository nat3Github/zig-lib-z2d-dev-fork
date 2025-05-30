// SPDX-License-Identifier: 0BSD
//   Copyright © 2025 Chris Marchesi

//! Demonstrates dithering in a context.
//!
//! This is a subset of 068, with just the grayscale part (albeit just the
//! alpha4 part and in reverse, black to white).
//!
//! This also tests blue noise (not tested in the other test).
const math = @import("std").math;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "069_gradient_dither_context";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    var dst_sfc = try z2d.Surface.init(.image_surface_alpha4, alloc, 400, 150);
    var gradient = z2d.Gradient.init(.{
        .type = .{ .linear = .{
            .x0 = 0,
            .y0 = 25,
            .x1 = 400,
            .y1 = 25,
        } },
    });
    defer gradient.deinit(alloc);
    try gradient.addStop(alloc, 0, .{ .rgba = .{ 0, 0, 0, 0 } });
    try gradient.addStop(alloc, 1, .{ .rgba = .{ 1, 1, 1, 1 } });
    var context = z2d.Context.init(alloc, &dst_sfc);
    defer context.deinit();
    context.setAntiAliasingMode(aa_mode);
    context.setSource(gradient.asPattern());
    try context.moveTo(0, 0);
    try context.lineTo(400, 0);
    try context.lineTo(400, 50);
    try context.lineTo(0, 50);
    try context.closePath();
    try context.fill();

    context.resetPath();
    context.translate(0, 50);
    context.setSource(gradient.asPattern());
    context.setDither(.bayer);
    try context.moveTo(0, 0);
    try context.lineTo(400, 0);
    try context.lineTo(400, 50);
    try context.lineTo(0, 50);
    try context.closePath();
    try context.fill();

    context.resetPath();
    context.setIdentity();
    context.translate(0, 100);
    context.setSource(gradient.asPattern());
    context.setDither(.blue_noise);
    try context.moveTo(0, 0);
    try context.lineTo(400, 0);
    try context.lineTo(400, 50);
    try context.lineTo(0, 50);
    try context.closePath();
    try context.fill();

    return dst_sfc;
}
