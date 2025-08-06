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

const stroke_plotter_impl = @import("wgpu_stroke_plotter.zig");
const join = stroke_plotter_impl.join;
const plotOpenJoined = stroke_plotter_impl.plotOpenJoined;
const plotSingle = stroke_plotter_impl.plotSingle;
const plotClosedJoined = stroke_plotter_impl.plotClosedJoined;

const PlotterOptions = stroke_plotter_impl.PlotterOptions;

const InternalError = @import("InternalError.zig").InternalError;
const Error = stroke_plotter_impl.Error;

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

        .result_polygon = WgpuPolygon.init(alloc),
        .current_outer_segment_points = std.ArrayList(Point).init(alloc),
        .current_inner_segment_points = std.ArrayList(Point).init(alloc),
        .points = std.ArrayList(Point).init(alloc),

        .dasher = Dasher.init(opts.dashes, opts.dash_offset),
        .initial_polygon = .{ .none = {} },
    };

    errdefer {
        plotter.result_polygon.deinit();
        plotter.current_outer_segment_points.deinit();
        plotter.current_inner_segment_points.deinit();
        plotter.points.deinit();
        if (plotter.initial_polygon == .on) {
            plotter.initial_polygon.on.deinit();
        }
    }

    defer if (plotter.pen) |*p| p.deinit(alloc);

    try plotter.run();

    try plotter.finish();

    return plotter.result_polygon;
}

const DashedPlotter = struct {
    const InitialPolygon = struct {
        alloc: mem.Allocator,
        opts: *const PlotterOptions,
        pen: ?Pen,
        points: std.ArrayList(Point),
        clockwise_: ?bool,
        initial_outer_segment_points: std.ArrayList(Point),
        initial_inner_segment_points: std.ArrayList(Point),
        current_slope: Slope,

        pub fn deinit(self: *@This()) void {
            self.points.deinit();
            self.initial_outer_segment_points.deinit();
            self.initial_inner_segment_points.deinit();
        }
    };

    alloc: mem.Allocator,
    nodes: []const nodepkg.PathNode,
    opts: *const PlotterOptions,

    pen: ?Pen,

    points: std.ArrayList(Point),
    clockwise_: ?bool = null,

    result_polygon: WgpuPolygon,
    current_outer_segment_points: std.ArrayList(Point),
    current_inner_segment_points: std.ArrayList(Point),

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
        self.points.clearAndFree();
        try self.points.append(node.point);
    }

    fn runLineTo(self: *DashedPlotter, node: nodepkg.PathLineTo) Error!void {
        return self._runLineTo(self.opts.join_mode, node);
    }

    fn _runLineTo(
        self: *DashedPlotter,
        join_mode: options.JoinMode,
        node: nodepkg.PathLineTo,
    ) Error!void {
        const current_point = self.points.items[self.points.items.len - 1];
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
            if (!current_dash_point.equal(self.points.items[self.points.items.len - 1])) {
                try self.points.append(current_dash_point);
            }
            if (self.dasher.on) {
                if (self.points.items.len > 2) {
                    try join(
                        DashedPlotter,
                        self,
                        join_mode,
                        self.points.items[self.points.items.len - 3],
                        self.points.items[self.points.items.len - 2],
                        self.points.items[self.points.items.len - 1],
                    );
                }
            }
            if (self.dasher.step(step_len)) {
                try self.nextSegment(current_dash_point);
            }
        }
    }

    fn runCurveTo(self: *DashedPlotter, node: nodepkg.PathCurveTo) Error!void {
        const current_point = self.points.items[self.points.items.len - 1];
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
        if (self.points.items.len <= 0) return InternalError.InvalidState;
        try self._runLineTo(self.opts.join_mode, .{
            .point = switch (self.initial_polygon) {
                .on => |poly| pt: {
                    break :pt poly.points.items[0];
                },
                .off => |initial_point| initial_point,
                else => self.points.items[0],
            },
        });
        switch (self.initial_polygon) {
            .on => |poly_state| {
                if (self.dasher.on and self.points.items.len > 1) {
                    debug.assert(poly_state.points.items.len > 0);
                    if (poly_state.points.items.len == 1) {
                        try plotOpenJoined(
                            DashedPlotter,
                            self,
                            self.points.items[0],
                            self.points.items[1],
                            self.points.items[self.points.items.len - 2],
                            self.points.items[self.points.items.len - 1],
                        );
                        self.initial_polygon = .{ .none = {} };
                    } else {
                        try self.joinAndCapInitial();
                    }
                } else {
                    switch (poly_state.points.items.len) {
                        0 => return InternalError.InvalidState,
                        1 => try self.finishInitialDotted(),
                        else => try self.finishInitial(
                            poly_state.points.items[0],
                            poly_state.points.items[1],
                        ),
                    }
                }
            },
            .off => {
                self.initial_polygon = .{ .none = {} };
            },
            .none => {
                switch (self.points.items.len) {
                    0 => unreachable,
                    1 => try self.plotDotted(self.points.items[0], self.current_slope),
                    2 => try plotSingle(
                        DashedPlotter,
                        self,
                        self.points.items[0],
                        self.points.items[1],
                    ),
                    else => {
                        const initial_point = self.points.items[0];
                        const second_point = self.points.items[1];
                        const last_point = self.points.items[self.points.items.len - 1];
                        const second_to_last_point = self.points.items[self.points.items.len - 2];

                        try plotClosedJoined(
                            DashedPlotter,
                            self,
                            initial_point,
                            second_point,
                            second_to_last_point,
                            last_point,
                        );
                    },
                }
            },
        }
        self.points.clearAndFree();
        self.clockwise_ = null;
    }

    fn finalizeCurrentSegment(self: *DashedPlotter) Error!void {
        if (self.current_outer_segment_points.items.len > 0) {
            try self.result_polygon.finalize_current_contour();
            for (self.current_outer_segment_points.items) |p| {
                try self.result_polygon.append_point(p);
            }
            try self.result_polygon.finalize_current_contour();

            try self.result_polygon.finalize_current_contour();
            for (0..self.current_inner_segment_points.items.len) |k| {
                try self.result_polygon.append_point(self.current_inner_segment_points.items[self.current_inner_segment_points.items.len - 1 - k]);
            }
            try self.result_polygon.finalize_current_contour();

            self.current_outer_segment_points.clearRetainingCapacity();
            self.current_inner_segment_points.clearRetainingCapacity();
        }
    }

    fn nextSegment(self: *DashedPlotter, point: Point) Error!void {
        if (self.initial_polygon == .none)
            self.saveInitial()
        else if (!self.dasher.on) {
            if (self.points.items.len == 1) {
                try self.plotDotted(self.points.items[0], self.current_slope);
            } else if (self.points.items.len >= 2) {
                if (self.points.items.len == 2) {
                    try plotSingle(
                        DashedPlotter,
                        self,
                        self.points.items[0],
                        self.points.items[1],
                    );
                } else {
                    try plotOpenJoined(
                        DashedPlotter,
                        self,
                        self.points.items[0],
                        self.points.items[1],
                        self.points.items[self.points.items.len - 2],
                        self.points.items[self.points.items.len - 1],
                    );
                }
            }
            self.current_outer_segment_points.clearRetainingCapacity();
            self.current_inner_segment_points.clearRetainingCapacity();
        }
        self.points.clearAndFree();
        try self.points.append(point);
    }

    fn finish(self: *DashedPlotter) Error!void {
        switch (self.initial_polygon) {
            .on => |poly_state| {
                switch (poly_state.points.items.len) {
                    0 => return InternalError.InvalidState,
                    1 => try self.finishInitialDotted(),
                    else => try self.finishInitial(
                        poly_state.points.items[0],
                        poly_state.points.items[1],
                    ),
                }
            },
            .off => self.initial_polygon = .{ .none = {} },
            .none => {},
        }
        if (self.dasher.on) {
            if (self.points.items.len == 1) {
                try self.plotDotted(self.points.items[0], self.current_slope);
            } else if (self.points.items.len >= 2) {
                if (self.points.items.len == 2) {
                    try plotSingle(
                        DashedPlotter,
                        self,
                        self.points.items[0],
                        self.points.items[1],
                    );
                } else {
                    try plotOpenJoined(
                        DashedPlotter,
                        self,
                        self.points.items[0],
                        self.points.items[1],
                        self.points.items[self.points.items.len - 2],
                        self.points.items[self.points.items.len - 1],
                    );
                }
            }
            self.current_outer_segment_points.clearRetainingCapacity();
            self.current_inner_segment_points.clearRetainingCapacity();
        }
    }

    fn plotDotted(self: *DashedPlotter, point: Point, current_slope: Slope) Error!void {
        switch (self.opts.cap_mode) {
            .round => {
                debug.assert(self.pen != null);
                try self.result_polygon.finalize_current_contour();
                for (self.pen.?.vertices.items) |v| {
                    try self.result_polygon.append_point(
                        .{
                            .x = point.x + v.point.x,
                            .y = point.y + v.point.y,
                        },
                    );
                }
                try self.result_polygon.finalize_current_contour();
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

                try self.result_polygon.finalize_current_contour();
                try self.result_polygon.append_point(
                    .{
                        .x = face.p1_cw.x - offset_x,
                        .y = face.p1_cw.y - offset_y,
                    },
                );
                try self.result_polygon.append_point(
                    .{
                        .x = face.p1_cw.x + offset_x,
                        .y = face.p1_cw.y + offset_y,
                    },
                );
                try self.result_polygon.append_point(
                    .{
                        .x = face.p1_ccw.x + offset_x,
                        .y = face.p1_ccw.y + offset_y,
                    },
                );
                try self.result_polygon.append_point(
                    .{
                        .x = face.p1_ccw.x - offset_x,
                        .y = face.p1_ccw.y - offset_y,
                    },
                );

                try self.result_polygon.finalize_current_contour();
            },
            else => {},
        }
        self.clockwise_ = null;
    }

    fn saveInitial(
        self: *DashedPlotter,
    ) void {
        if (!self.dasher.on) {
            self.initial_polygon = .{
                .on = .{
                    .alloc = self.alloc,
                    .opts = self.opts,
                    .pen = self.pen,
                    .points = self.points,
                    .clockwise_ = self.clockwise_,
                    .initial_outer_segment_points = self.current_outer_segment_points,
                    .initial_inner_segment_points = self.current_inner_segment_points,
                    .current_slope = self.current_slope,
                },
            };
            self.points = std.ArrayList(Point).init(self.alloc);
            self.current_outer_segment_points = std.ArrayList(Point).init(self.alloc);
            self.current_inner_segment_points = std.ArrayList(Point).init(self.alloc);
        } else {
            debug.assert(self.points.items.len > 0);
            self.initial_polygon = .{ .off = self.points.items[0] };
        }

        self.points.clearAndFree();
        self.clockwise_ = null;
    }

    fn finishInitialDotted(
        self: *DashedPlotter,
    ) Error!void {
        if (self.initial_polygon != .on) return InternalError.InvalidState;
        var initial_poly_state = self.initial_polygon.on;
        try self.plotDotted(
            initial_poly_state.points.items[0],
            initial_poly_state.current_slope,
        );
        initial_poly_state.deinit();
        self.initial_polygon = .{ .none = {} };
    }

    fn finishInitial(
        self: *DashedPlotter,
        _: Point,
        _: Point,
    ) Error!void {
        if (self.initial_polygon != .on) return InternalError.InvalidState;
        var initial_poly_state = self.initial_polygon.on;

        var temp_plotter_ctx: struct {
            result_polygon: *WgpuPolygon,
            current_outer_segment_points: std.ArrayList(Point),
            current_inner_segment_points: std.ArrayList(Point),
            opts: *const PlotterOptions,
            pen: ?Pen,
            clockwise_: ?bool,
            alloc: mem.Allocator,
        } = .{
            .result_polygon = &self.result_polygon,
            .current_outer_segment_points = initial_poly_state.initial_outer_segment_points,
            .current_inner_segment_points = initial_poly_state.initial_inner_segment_points,
            .opts = self.opts,
            .pen = self.pen,
            .clockwise_ = self.clockwise_,
            .alloc = self.alloc,
        };

        try plotOpenJoined(
            @TypeOf(temp_plotter_ctx),
            &temp_plotter_ctx,
            initial_poly_state.points.items[0],
            initial_poly_state.points.items[1],
            initial_poly_state.points.items[initial_poly_state.points.items.len - 2],
            initial_poly_state.points.items[initial_poly_state.points.items.len - 1],
        );
        initial_poly_state.deinit();
        self.initial_polygon = .{ .none = {} };
    }

    fn joinAndCapInitial(self: *DashedPlotter) Error!void {
        if (self.initial_polygon != .on) return InternalError.InvalidState;
        var initial_poly_state = self.initial_polygon.on;

        const temp_initial_ctx: struct {
            result_polygon: *WgpuPolygon,
            current_outer_segment_points: std.ArrayList(Point),
            current_inner_segment_points: std.ArrayList(Point),
            opts: *const PlotterOptions,
            pen: ?Pen,
            clockwise_: ?bool,
            alloc: mem.Allocator,
        } = .{
            .result_polygon = &self.result_polygon,
            .current_outer_segment_points = initial_poly_state.initial_outer_segment_points,
            .current_inner_segment_points = initial_poly_state.initial_inner_segment_points,
            .opts = self.opts,
            .pen = self.pen,
            .clockwise_ = self.clockwise_,
            .alloc = self.alloc,
        };

        if (self.points.items.len > 2) {
            try join(
                DashedPlotter,
                self,
                self.opts.join_mode,
                self.points.items[self.points.items.len - 3],
                self.points.items[self.points.items.len - 2],
                initial_poly_state.points.items[0],
            );

            try self.current_outer_segment_points.appendSlice(temp_initial_ctx.current_outer_segment_points.items);
            try self.current_inner_segment_points.appendSlice(temp_initial_ctx.current_inner_segment_points.items);

            try plotClosedJoined(
                DashedPlotter,
                self,
                self.points.items[0],
                self.points.items[1],
                initial_poly_state.points.items[initial_poly_state.points.items.len - 2],
                initial_poly_state.points.items[initial_poly_state.points.items.len - 1],
            );
        } else {
            try join(
                DashedPlotter,
                self,
                self.opts.join_mode,
                self.points.items[0],
                self.points.items[1],
                initial_poly_state.points.items[0],
            );

            try plotClosedJoined(
                DashedPlotter,
                self,
                self.points.items[0],
                initial_poly_state.points.items[0],
                initial_poly_state.points.items[initial_poly_state.points.items.len - 2],
                initial_poly_state.points.items[initial_poly_state.points.items.len - 1],
            );
        }

        initial_poly_state.deinit();
        self.initial_polygon = .{ .none = {} };
        self.current_outer_segment_points.clearRetainingCapacity();
        self.current_inner_segment_points.clearRetainingCapacity();
        self.clockwise_ = null;
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

// SPDX-License-Identifier: MPL-2.0
//    Copyright © 2024-2025 Chris Marchesi
