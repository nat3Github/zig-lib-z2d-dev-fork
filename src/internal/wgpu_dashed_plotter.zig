// dashed_plotter.zig (modified for WgpuPolygon)
// SPDX-License-Identifier: MPL-2.0
//    Copyright © 2024-2025 Chris Marchesi

const std = @import("std");
const debug = @import("std").debug;
const mem = @import("std").mem;
const testing = @import("std").testing;

const options = @import("../options.zig");
const nodepkg = @import("path_nodes.zig");

const Dasher = @import("Dasher.zig");
const Face = @import("Face.zig");
const Pen = @import("Pen.zig");
const PlotterVTable = @import("PlotterVTable.zig");
const Point = @import("Point.zig");
const WgpuPolygon = @import("wgpu_Polygon.zig");
const Slope = @import("Slope.zig");
const Spline = @import("Spline.zig");
const Transformation = @import("../Transformation.zig");

const PointBuffer = @import("util.zig").PointBuffer(2, 5);
const PlotterOptions = @import("wgpu_stroke_plotter.zig").PlotterOptions;

const InternalError = @import("InternalError.zig").InternalError;
const Error = @import("wgpu_stroke_plotter.zig").Error;

pub fn plot(
    alloc: mem.Allocator,
    nodes: []const nodepkg.PathNode,
    opts: PlotterOptions,
) Error!WgpuPolygon {
    var plotter: DashedPlotter = .{
        .alloc = alloc,
        .nodes = nodes,
        .opts = &opts,

        .pen = if (opts.join_mode == .round or opts.cap_mode == .round)
            try Pen.init(alloc, opts.thickness, opts.tolerance, opts.ctm)
        else
            null,

        .result = WgpuPolygon.init(alloc),
        .dasher = Dasher.init(opts.dashes, opts.dash_offset),
        .initial_polygon = .{ .none = {} },
    };

    errdefer {
        plotter.result.deinit();
    }

    defer if (plotter.pen) |*p| p.deinit(alloc);

    try plotter.run();

    try plotter.finish();

    return plotter.result;
}

const DashedPlotter = struct {
    const InitialPolygon = struct {
        points: PointBuffer,
        clockwise_: ?bool,
        current_slope: Slope,
    };

    alloc: mem.Allocator,
    nodes: []const nodepkg.PathNode,
    opts: *const PlotterOptions,

    pen: ?Pen,

    points: PointBuffer = .{},
    clockwise_: ?bool = null,

    result: WgpuPolygon,

    dasher: Dasher,
    current_slope: Slope = undefined,
    initial_polygon: union(enum) { none: void, off: Point, on: InitialPolygon } = .{ .none = {} },

    fn run(self: *DashedPlotter) Error!void {
        for (0..self.nodes.len) |idx| {
            switch (self.nodes[idx]) {
                .move_to => |n| try self.runMoveTo(n),
                .line_to => |n| try self.runLineTo(n),
                .curve_to => |n| try self.runCurveTo(n),
                .close_path => try self.runClosePath(),
            }
        }
    }

    fn runMoveTo(self: *DashedPlotter, node: nodepkg.PathMoveTo) Error!void {
        try self.finish();
        self.dasher.reset();
        self.points.reset();
        self.points.add(node.point);
    }

    fn runLineTo(self: *DashedPlotter, node: nodepkg.PathLineTo) Error!void {
        return self._runLineTo(self.opts.join_mode, node);
    }

    fn _runLineTo(
        self: *DashedPlotter,
        join_mode: options.JoinMode,
        node: nodepkg.PathLineTo,
    ) Error!void {
        const current_point = self.points.last() orelse return InternalError.InvalidState;
        if (node.point.equal(current_point)) {
            return;
        }
        const first_dash_point = current_point;
        var slope = Slope.init(first_dash_point, node.point);
        self.current_slope = slope;
        _ = self.current_slope.normalize();
        self.opts.ctm.deviceToUserDistance(&slope.dx, &slope.dy) catch unreachable;
        const total_len = slope.normalize();
        var remaining_len = total_len;
        var step_len = @min(self.dasher.remain, remaining_len);
        while (remaining_len > 0) : (step_len = @min(self.dasher.remain, remaining_len)) {
            remaining_len -= step_len;
            var x_offset = slope.dx * (total_len - remaining_len);
            var y_offset = slope.dy * (total_len - remaining_len);
            self.opts.ctm.userToDeviceDistance(&x_offset, &y_offset);
            const current_dash_point: Point = .{
                .x = first_dash_point.x + x_offset,
                .y = first_dash_point.y + y_offset,
            };
            if (!current_dash_point.equal(self.points.last() orelse unreachable)) {
                self.points.add(current_dash_point);
            }
            if (self.dasher.on) {
                if (self.points.len > 2) {
                    try self.addJoin(
                        join_mode,
                        self.points.tail(3) orelse unreachable,
                        self.points.tail(2) orelse unreachable,
                        self.points.tail(1) orelse unreachable,
                    );
                }
            }
            if (self.dasher.step(step_len)) {
                try self.nextSegment(current_dash_point);
            }
        }
    }

    fn runCurveTo(self: *DashedPlotter, node: nodepkg.PathCurveTo) Error!void {
        const current_point = self.points.last() orelse return InternalError.InvalidState;
        if (self.pen == null) self.pen = try Pen.init(
            self.alloc,
            self.opts.thickness,
            self.opts.tolerance,
            self.opts.ctm,
        );

        var plotter_ctx: CurveToCtx = .{ .plotter = self };
        var spline: Spline = .{
            .a = current_point,
            .b = node.p1,
            .c = node.p2,
            .d = node.p3,
            .tolerance = self.opts.tolerance,
            .plotter_impl = &.{
                .ptr = &plotter_ctx,
                .line_to = CurveToCtx.line_to,
            },
        };
        try spline.decompose();
    }

    fn runClosePath(self: *DashedPlotter) Error!void {
        if (self.points.len <= 0) return InternalError.InvalidState;
        try self._runLineTo(self.opts.join_mode, .{
            .point = switch (self.initial_polygon) {
                .on => |poly| pt: {
                    break :pt poly.points.first() orelse return InternalError.InvalidState;
                },
                .off => |initial_point| initial_point,
                else => self.points.first() orelse unreachable,
            },
        });
        switch (self.initial_polygon) {
            .on => |poly| {
                if (self.dasher.on and self.points.len > 1) {
                    debug.assert(poly.points.len > 0);
                    if (poly.points.len == 1) {
                        try self.addCap(
                            self.points.head(0) orelse unreachable,
                            self.points.head(1) orelse unreachable,
                        );
                        self.initial_polygon = .{ .none = {} };
                    } else {
                        try self.joinAndCloseInitial();
                    }
                } else {
                    switch (poly.points.len) {
                        0 => return InternalError.InvalidState,
                        1 => try self.finishInitialDotted(),
                        else => try self.finishInitial(
                            poly.points.head(0) orelse unreachable,
                            poly.points.head(1) orelse unreachable,
                        ),
                    }
                }
            },
            .off => {
                self.initial_polygon = .{ .none = {} };
            },
            .none => {
                switch (self.points.len) {
                    0 => unreachable,
                    1 => try self.plotDotted(self.points.first() orelse unreachable, self.current_slope),
                    2 => try self.addCap(
                        self.points.head(0) orelse unreachable,
                        self.points.head(1) orelse unreachable,
                    ),
                    else => {
                        try self.addJoin(
                            self.opts.join_mode,
                            self.points.tail(2) orelse unreachable,
                            self.points.head(0) orelse unreachable,
                            self.points.head(1) orelse unreachable,
                        );
                        try self.result.finalize_current_contour();
                    },
                }
            },
        }
        self.points.reset();
    }

    fn nextSegment(self: *DashedPlotter, point: Point) Error!void {
        if (self.initial_polygon == .none)
            self.saveInitial()
        else if (!self.dasher.on) {
            switch (self.points.len) {
                0 => {},
                1 => try self.plotDotted(self.points.first() orelse unreachable, self.current_slope),
                else => try self.addCap(
                    self.points.head(0) orelse unreachable,
                    self.points.head(1) orelse unreachable,
                ),
            }
            try self.result.finalize_current_contour();
        }
        self.points.reset();
        self.points.add(point);
    }

    fn finish(self: *DashedPlotter) Error!void {
        switch (self.initial_polygon) {
            .on => |poly| {
                switch (poly.points.len) {
                    0 => return InternalError.InvalidState,
                    1 => try self.finishInitialDotted(),
                    else => try self.finishInitial(
                        poly.points.head(0) orelse unreachable,
                        poly.points.head(1) orelse unreachable,
                    ),
                }
            },
            .off => self.initial_polygon = .{ .none = {} },
            .none => {},
        }
        if (self.dasher.on) switch (self.points.len) {
            0 => {},
            1 => try self.plotDotted(self.points.first() orelse unreachable, self.current_slope),
            else => try self.addCap(
                self.points.head(0) orelse unreachable,
                self.points.head(1) orelse unreachable,
            ),
        };
        try self.result.finalize_current_contour();
    }

    fn plotDotted(self: *DashedPlotter, point: Point, current_slope: Slope) Error!void {
        switch (self.opts.cap_mode) {
            .round => {
                debug.assert(self.pen != null);
                for (self.pen.?.vertices.items) |v| {
                    try self.result.append_point(.{
                        .x = point.x + v.point.x,
                        .y = point.y + v.point.y,
                    });
                }
                try self.result.finalize_current_contour();
            },
            .square => {
                const face = Face.initSingle(
                    point,
                    current_slope,
                    self.opts.thickness,
                    self.opts.ctm,
                );
                var offset_x = face.user_slope.dx * face.half_width;
                var offset_y = face.user_slope.dy * face.half_width;
                self.opts.ctm.userToDeviceDistance(&offset_x, &offset_y);

                try self.result.append_point(.{
                    .x = face.p1_cw.x - offset_x,
                    .y = face.p1_cw.y - offset_y,
                });
                try self.result.append_point(.{
                    .x = face.p1_cw.x + offset_x,
                    .y = face.p1_cw.y + offset_y,
                });
                try self.result.append_point(.{
                    .x = face.p1_ccw.x + offset_x,
                    .y = face.p1_ccw.y + offset_y,
                });
                try self.result.append_point(.{
                    .x = face.p1_ccw.x - offset_x,
                    .y = face.p1_ccw.y - offset_y,
                });

                try self.result.finalize_current_contour();
            },
            else => {},
        }
        self.clockwise_ = null;
    }

    fn addCap(self: *DashedPlotter, p0: Point, p1: Point) Error!void {
        const face = Face.init(p0, p1, self.opts.thickness, self.opts.ctm);

        try self.result.append_point(face.p0_ccw);
        try self.result.append_point(face.p1_ccw);
        try self.result.append_point(face.p1_cw);
        try self.result.append_point(face.p0_cw);

        try self.result.finalize_current_contour();
    }

    fn addJoin(self: *DashedPlotter, _: options.JoinMode, p0: Point, p1: Point, p2: Point) Error!void {
        const face_prev = Face.init(p0, p1, self.opts.thickness, self.opts.ctm);
        const face_next = Face.init(p1, p2, self.opts.thickness, self.opts.ctm);

        try self.result.append_point(face_prev.p1_ccw);
        try self.result.append_point(face_next.p0_ccw);
        try self.result.finalize_current_contour();

        try self.result.append_point(face_prev.p1_cw);
        try self.result.append_point(face_next.p0_cw);
        try self.result.finalize_current_contour();
    }

    fn saveInitial(
        self: *DashedPlotter,
    ) void {
        if (!self.dasher.on) {
            self.initial_polygon = .{ .on = .{
                .points = self.points,
                .clockwise_ = self.clockwise_,
                .current_slope = self.current_slope,
            } };
        } else {
            debug.assert(self.points.len > 0);
            self.initial_polygon = .{ .off = self.points.first() orelse unreachable };
        }

        self.points.reset();
        self.clockwise_ = null;
    }

    fn finishInitialDotted(
        self: *DashedPlotter,
    ) Error!void {
        if (self.initial_polygon != .on) return InternalError.InvalidState;
        const initial_poly_state = self.initial_polygon.on;
        try self.plotDotted(
            initial_poly_state.points.first() orelse return InternalError.InvalidState,
            initial_poly_state.current_slope,
        );
        self.initial_polygon = .{ .none = {} };
    }

    fn finishInitial(
        self: *DashedPlotter,
        _: Point,
        _: Point,
    ) Error!void {
        if (self.initial_polygon != .on) return InternalError.InvalidState;
        const initial_poly_state = self.initial_polygon.on;

        try self.addCap(
            initial_poly_state.points.head(0) orelse unreachable,
            initial_poly_state.points.head(1) orelse unreachable,
        );

        self.initial_polygon = .{ .none = {} };
    }

    fn joinAndCloseInitial(self: *DashedPlotter) Error!void {
        if (self.initial_polygon != .on) return InternalError.InvalidState;
        const initial_poly_state = self.initial_polygon.on;

        if (self.points.len > 2) {
            try self.addJoin(
                self.opts.join_mode,
                self.points.tail(2) orelse unreachable,
                self.points.tail(1) orelse unreachable,
                initial_poly_state.points.head(1) orelse return InternalError.InvalidState,
            );
        } else {
            try self.addJoin(
                self.opts.join_mode,
                self.points.head(0) orelse unreachable,
                initial_poly_state.points.head(0) orelse return InternalError.InvalidState,
                initial_poly_state.points.head(1) orelse return InternalError.InvalidState,
            );
        }

        try self.result.finalize_current_contour();
        self.initial_polygon = .{ .none = {} };
    }

    const CurveToCtx = struct {
        plotter: *DashedPlotter,

        fn line_to(ctx: *anyopaque, err_: *?PlotterVTable.Error, node: nodepkg.PathLineTo) void {
            const self: *CurveToCtx = @ptrCast(@alignCast(ctx));
            self.plotter._runLineTo(.round, node) catch |err| {
                err_.* = err;
            };
        }
    };
};
