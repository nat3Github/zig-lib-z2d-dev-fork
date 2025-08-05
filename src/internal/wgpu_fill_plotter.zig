//! A polygon plotter for fill operations.
const std = @import("std");
const debug = @import("std").debug;
const mem = @import("std").mem;
const testing = @import("std").testing;

const nodepkg = @import("path_nodes.zig");

const WgpuPolygon = @import("wgpu_Polygon.zig");
const Point = @import("Point.zig");
const Spline = @import("Spline.zig");
const PlotterVTable = @import("PlotterVTable.zig");
const InternalError = @import("InternalError.zig").InternalError;

pub const Error = InternalError || mem.Allocator.Error;

pub fn plot(
    alloc: mem.Allocator,
    nodes: []const nodepkg.PathNode,
    tolerance: f64,
) !WgpuPolygon {
    var contours = WgpuPolygon.init(alloc);
    var current_path_start_point: ?Point = null;
    for (nodes, 0..) |node, i| {
        switch (node) {
            .move_to => |n| {
                if (i == nodes.len - 1) break;
                try contours.finalize_current_contour();
                try contours.append_point(n.point);
                current_path_start_point = n.point;
            },
            .line_to => |n| {
                const last_point = contours.last_current_point() orelse return error.InvalidState;
                if (!last_point.equal(n.point)) {
                    try contours.append_point(n.point);
                }
            },
            .curve_to => |n| {
                const last_point = contours.last_current_point() orelse return error.InvalidState;
                if (last_point.equal(n.p3)) continue;

                var spline_ctx: WgpuSplinePlotterCtx = .{
                    .contour_list = &contours,
                    .alloc = alloc,
                };
                var spline: Spline = .{
                    .a = last_point,
                    .b = n.p1,
                    .c = n.p2,
                    .d = n.p3,
                    .tolerance = tolerance,
                    .plotter_impl = &.{
                        .ptr = &spline_ctx,
                        .line_to = WgpuSplinePlotterCtx.line_to_add_to_contour,
                    },
                };
                try spline.decompose();
            },
            .close_path => {
                const current_len = contours.current_contour_len();
                if (current_len < 2) return error.InvalidState;
                const last_point = contours.last_current_point().?;
                const first_point_of_path = current_path_start_point.?;
                if (!last_point.equal(first_point_of_path)) {
                    try contours.append_point(first_point_of_path);
                }
                try contours.finalize_current_contour();
                current_path_start_point = null;
            },
        }
    }
    try contours.finalize_current_contour();
    return contours;
}

const WgpuSplinePlotterCtx = struct {
    contour_list: *WgpuPolygon,
    alloc: mem.Allocator,
    fn line_to_add_to_contour(ctx: *anyopaque, err_: *?PlotterVTable.Error, node: nodepkg.PathLineTo) void {
        const self: *WgpuSplinePlotterCtx = @ptrCast(@alignCast(ctx));
        if (self.contour_list.last_current_point()) |last_p| {
            if (last_p.equal(node.point)) {
                return;
            }
        }
        self.contour_list.append_point(node.point) catch |err| {
            err_.* = err;
            return;
        };
    }
};

// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi
