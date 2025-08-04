// SPDX-License-Identifier: MPL-2.0
//    Copyright © 2024-2025 Chris Marchesi

const std = @import("std");
const debug = @import("std").debug;
const math = @import("std").math;
const mem = @import("std").mem;
const testing = @import("std").testing;

const dashed_plotter = @import("dashed_plotter.zig");
const nodepkg = @import("path_nodes.zig");
const options = @import("../options.zig");

const Dasher = @import("Dasher.zig");
const Face = @import("Face.zig");
const Pen = @import("Pen.zig");
const PlotterVTable = @import("PlotterVTable.zig");
const Point = @import("Point.zig");
// const Polygon = @import("Polygon.zig"); // Original Polygon, no longer used directly for output
const WgpuPolygon = @import("wgpu_Polygon.zig"); // The new Polygon representation
const Slope = @import("Slope.zig");
const Spline = @import("Spline.zig");
const Transformation = @import("../Transformation.zig");
const PointBuffer = @import("util.zig").PointBuffer(2, 5);

const InternalError = @import("InternalError.zig").InternalError;
pub const Error = InternalError || mem.Allocator.Error;

pub const PlotterOptions = struct {
    cap_mode: options.CapMode,
    ctm: Transformation,
    dashes: []const f64,
    dash_offset: f64,
    join_mode: options.JoinMode,
    miter_limit: f64,
    scale: f64, // Keep scale, it's used in transformations
    thickness: f64,
    tolerance: f64,
};

pub fn plot(
    alloc: mem.Allocator,
    nodes: []const nodepkg.PathNode,
    opts: PlotterOptions,
) Error!WgpuPolygon { // Return WgpuPolygon directly
    if (Dasher.validate(opts.dashes)) {
        // IMPORTANT: dashed_plotter.zig must also be adapted to return WgpuPolygon.
        // If not, this line will cause a type mismatch.
        unreachable;
        // return dashed_plotter.plot(alloc, nodes, opts);
    }

    var plotter = try Plotter.init(alloc, &opts);
    plotter.nodes = nodes; // Set nodes after init

    errdefer plotter.deinit();
    defer if (plotter.pen) |*p| p.deinit(alloc);

    try plotter.run();

    // plotter.result_polygon now holds all the contours for the stroke.
    return plotter.result_polygon;
}

const Plotter = struct {
    alloc: mem.Allocator,
    nodes: []const nodepkg.PathNode, // Made mutable for setting after init
    opts: *const PlotterOptions,

    pen: ?Pen,

    points: PointBuffer = .{}, // point buffer for path segment (p0, p1, p2)
    clockwise_: ?bool = null, // clockwise state

    // Instead of `Polygon.Contour`, use `ArrayList` as temporary buffers for the current stroke segment
    current_outer_segment_points: std.ArrayList(Point),
    current_inner_segment_points: std.ArrayList(Point),

    // The final result WgpuPolygon
    result_polygon: WgpuPolygon,

    // Store the start point of the current logical path (after a move_to)
    current_logical_path_start_point: ?Point = null,

    // Initialization for Plotter will change
    pub fn init(alloc: mem.Allocator, opts: *const PlotterOptions) Error!@This() {
        return .{
            .alloc = alloc,
            .nodes = &.{}, // Will be set by caller
            .opts = opts,
            .pen = null, // Will be lazy-init
            .current_outer_segment_points = std.ArrayList(Point).init(alloc),
            .current_inner_segment_points = std.ArrayList(Point).init(alloc),
            .result_polygon = WgpuPolygon.init(alloc),
            .current_logical_path_start_point = null,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.current_outer_segment_points.deinit();
        self.current_inner_segment_points.deinit();
        self.result_polygon.deinit();
        if (self.pen) |*p| p.deinit(self.alloc);
    }

    fn run(self: *Plotter) Error!void {
        for (0..self.nodes.len) |idx| {
            switch (self.nodes[idx]) {
                .move_to => |n| try self.runMoveTo(n),
                .line_to => |n| try self.runLineTo(n),
                .curve_to => |n| try self.runCurveTo(n),
                .close_path => try self.runClosePath(),
            }
        }
        try self.finish();
    }

    fn runMoveTo(self: *Plotter, node: nodepkg.PathMoveTo) Error!void {
        if (self.points.len > 0) {
            // Before starting a new path, finalize the previous one if it exists
            try self.finish();
        }
        self.points.reset();
        self.points.add(node.point);
        self.current_logical_path_start_point = node.point;

        // Reset temporary buffers for the new path segment
        self.current_outer_segment_points.clearAndFree();
        self.current_inner_segment_points.clearAndFree();
    }

    fn runLineTo(self: *Plotter, node: nodepkg.PathLineTo) Error!void {
        try self._runLineTo(self.opts.join_mode, node);
    }

    fn _runLineTo(self: *Plotter, join_mode: options.JoinMode, node: nodepkg.PathLineTo) Error!void {
        const current_point = self.points.last() orelse return InternalError.InvalidState;
        if (node.point.equal(current_point)) {
            return; // consume degenerate nodes
        }
        self.points.add(node.point);

        if (self.points.len >= 3) {
            try join(
                @This(),
                self,
                join_mode,
                self.points.tail(3) orelse unreachable, // p0
                self.points.tail(2) orelse unreachable, // p1
                self.points.tail(1) orelse unreachable, // p2
            );
        }
    }

    fn runCurveTo(self: *Plotter, node: nodepkg.PathCurveTo) Error!void {
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

    fn runClosePath(self: *Plotter) Error!void {
        switch (self.points.len) {
            0 => {},
            1 => try self.plotDotted(self.points.first() orelse unreachable),
            2 => try plotSingle(
                @This(),
                self,
                self.points.head(0) orelse unreachable,
                self.points.head(1) orelse unreachable,
            ),
            else => {
                const initial_point = self.current_logical_path_start_point orelse return InternalError.InvalidState;
                try plotClosedJoined(
                    @This(),
                    self,
                    initial_point, // Use the logical start point
                    self.points.head(1) orelse unreachable, // Second point in `points` buffer
                    self.points.tail(2) orelse unreachable, // Second to last point in `points` buffer
                    self.points.tail(1) orelse unreachable, // Last point in `points` buffer
                );
            },
        }
        self.points.reset();
        self.clockwise_ = null; // Reset for next path
    }

    fn finish(self: *Plotter) Error!void {
        switch (self.points.len) {
            0, 1 => {},
            2 => try plotSingle(
                @This(),
                self,
                self.points.head(0) orelse unreachable,
                self.points.head(1) orelse unreachable,
            ),
            else => try plotOpenJoined(
                @This(),
                self,
                self.points.head(0) orelse unreachable,
                self.points.head(1) orelse unreachable,
                self.points.tail(2) orelse unreachable,
                self.points.tail(1) orelse unreachable,
            ),
        }
        self.points.reset();
        self.clockwise_ = null; // Reset for next path
    }

    fn plotDotted(self: *Plotter, point: Point) Error!void {
        debug.assert(self.current_inner_segment_points.items.len == 0); // Inner should be empty
        if (self.opts.cap_mode == .round) {
            debug.assert(self.pen != null);
            try self.result_polygon.finalize_current_contour(); // Ensure previous contour is finalized
            for (self.pen.?.vertices.items) |v| {
                try self.result_polygon.append_point(
                    .{
                        .x = point.x + v.point.x,
                        .y = point.y + v.point.y,
                    },
                );
            }
            try self.result_polygon.finalize_current_contour(); // Finalize the circle contour
        }
    }

    pub const CurveToCtx = struct {
        plotter: *Plotter,

        fn line_to(ctx: *anyopaque, err_: *?PlotterVTable.Error, node: nodepkg.PathLineTo) void {
            const self: *CurveToCtx = @ptrCast(@alignCast(ctx));
            self.plotter._runLineTo(.round, node) catch |err| {
                err_.* = err;
                return;
            };
        }
    };
};

// Adapted CapPlotterCtx for temporary ArrayLists
const CapPlotterCtx = struct {
    alloc: mem.Allocator,
    contour_points: *std.ArrayList(Point), // Points for the current cap
    // `before` is irrelevant here, as we only append to ArrayList
    fn line_to(ctx: *anyopaque, err_: *?PlotterVTable.Error, node: nodepkg.PathLineTo) void {
        const self: *CapPlotterCtx = @ptrCast(@alignCast(ctx));
        self.contour_points.append(node.point) catch |err| {
            err_.* = err;
            return;
        };
    }
};

// Adapted WgpuJoiner for temporary ArrayLists
const WgpuJoiner = struct {
    const Self = @This();
    plotter: *Plotter, // Reference to the main Plotter

    plot_fn: *const fn (
        *const @This(),
        *?mem.Allocator.Error,
        Point,
    ) void,

    fn plot(
        this: *const Self,
        point: Point,
    ) mem.Allocator.Error!void {
        var err_: ?mem.Allocator.Error = null;
        this.plot_fn(this, &err_, point);
        if (err_) |err| return err;
    }

    fn plotOuter(
        this: *const Self,
        err_: *?mem.Allocator.Error,
        point: Point,
    ) void {
        this.plotter.current_outer_segment_points.append(point) catch |err| {
            err_.* = err;
            return;
        };
    }

    fn plotInner(
        this: *const Self,
        err_: *?mem.Allocator.Error,
        point: Point,
    ) void {
        this.plotter.current_inner_segment_points.append(point) catch |err| {
            err_.* = err;
            return;
        };
    }
};

pub fn plotSingle(T: type, self: *T, start: Point, end: Point) Error!void {
    debug.assert(self.current_inner_segment_points.items.len == 0); // Inner should be empty for a single segment

    const cap_points_face = Face.init(
        start,
        end,
        self.opts.thickness,
        self.opts.ctm,
    );

    // This function plots a single *closed* rectangle for the stroke.
    // It will be added as one contour to `result_polygon`.
    try self.result_polygon.finalize_current_contour(); // Start new contour for this stroke

    var temp_cap_points = std.ArrayList(Point).init(self.alloc);
    defer temp_cap_points.deinit();

    var plotter_ctx: CapPlotterCtx = .{
        .alloc = self.alloc,
        .contour_points = &temp_cap_points,
    };

    // Plot points for the start cap
    try cap_points_face.cap_p0(
        &.{ .ptr = &plotter_ctx, .line_to = CapPlotterCtx.line_to },
        self.opts.cap_mode,
        true, // Clockwise for outer segment
        self.pen,
    );

    // Plot points for the end cap (this will append to the same temp_cap_points)
    try cap_points_face.cap_p1(
        &.{ .ptr = &plotter_ctx, .line_to = CapPlotterCtx.line_to },
        self.opts.cap_mode,
        true, // Clockwise for outer segment
        self.pen,
    );

    // Now, `temp_cap_points` contains all points for the single line's stroke rectangle.
    // Append them to the `result_polygon`.
    for (temp_cap_points.items) |p| {
        try self.result_polygon.append_point(p);
    }
    try self.result_polygon.finalize_current_contour();

    self.clockwise_ = null;
}

pub fn plotOpenJoined(
    T: type,
    self: *T,
    start0: Point,
    end0: Point,
    start1: Point,
    end1: Point,
) Error!void {
    const cap_points_start = Face.init(
        start0,
        end0,
        self.opts.thickness,
        self.opts.ctm,
    );
    const cap_points_end = Face.init(
        start1,
        end1,
        self.opts.thickness,
        self.opts.ctm,
    );

    const clockwise = if (self.clockwise_) |cw| cw else true;

    // This function processes a *single* open joined path segment.
    // The final result should be a single contour in `result_polygon`.
    try self.result_polygon.finalize_current_contour(); // Start a new contour for this stroke

    // 1. Add start cap points (outer side) to the result polygon
    var outer_start_cap_points = std.ArrayList(Point).init(self.alloc);
    defer outer_start_cap_points.deinit();
    var cap_ctx_outer_start: CapPlotterCtx = .{ .alloc = self.alloc, .contour_points = &outer_start_cap_points };
    try cap_points_start.cap_p0(
        &.{ .ptr = &cap_ctx_outer_start, .line_to = CapPlotterCtx.line_to },
        self.opts.cap_mode,
        clockwise, // Uses determined clockwise direction
        self.pen,
    );
    for (outer_start_cap_points.items) |p| {
        try self.result_polygon.append_point(p);
    }

    // 2. Add accumulated outer path segment points to the result polygon
    for (self.current_outer_segment_points.items) |p| {
        try self.result_polygon.append_point(p);
    }

    // 3. Add end cap points (outer side) to the result polygon
    var outer_end_cap_points = std.ArrayList(Point).init(self.alloc);
    defer outer_end_cap_points.deinit();
    var cap_ctx_outer_end: CapPlotterCtx = .{ .alloc = self.alloc, .contour_points = &outer_end_cap_points };
    try cap_points_end.cap_p1(
        &.{ .ptr = &cap_ctx_outer_end, .line_to = CapPlotterCtx.line_to },
        self.opts.cap_mode,
        clockwise, // Uses determined clockwise direction
        self.pen,
    );
    for (outer_end_cap_points.items) |p| {
        try self.result_polygon.append_point(p);
    }

    // 4. Add end cap points (inner side, reversed) to the result polygon
    // Note: cap_p1 is always from end to start, so for inner we reverse it.
    var inner_end_cap_points = std.ArrayList(Point).init(self.alloc);
    defer inner_end_cap_points.deinit();
    var cap_ctx_inner_end: CapPlotterCtx = .{ .alloc = self.alloc, .contour_points = &inner_end_cap_points };
    // The boolean `clockwise` passed to `cap_p1` controls which "side" of the cap is generated.
    // For the inner side, it's the opposite of the outer.
    try cap_points_end.cap_p1(
        &.{ .ptr = &cap_ctx_inner_end, .line_to = CapPlotterCtx.line_to },
        self.opts.cap_mode,
        !clockwise, // Opposite direction for inner cap
        self.pen,
    );
    // Append in reverse order
    for (0..inner_end_cap_points.items.len) |k| {
        try self.result_polygon.append_point(inner_end_cap_points.items[inner_end_cap_points.items.len - 1 - k]);
    }

    // 5. Add accumulated inner path segment points to the result polygon (in reverse order)
    for (0..self.current_inner_segment_points.items.len) |k| {
        try self.result_polygon.append_point(self.current_inner_segment_points.items[self.current_inner_segment_points.items.len - 1 - k]);
    }

    // 6. Add start cap points (inner side, reversed) to the result polygon
    var inner_start_cap_points = std.ArrayList(Point).init(self.alloc);
    defer inner_start_cap_points.deinit();
    var cap_ctx_inner_start: CapPlotterCtx = .{ .alloc = self.alloc, .contour_points = &inner_start_cap_points };
    try cap_points_start.cap_p0(
        &.{ .ptr = &cap_ctx_inner_start, .line_to = CapPlotterCtx.line_to },
        self.opts.cap_mode,
        !clockwise, // Opposite direction for inner cap
        self.pen,
    );
    // Append in reverse order
    for (0..inner_start_cap_points.items.len) |k| {
        try self.result_polygon.append_point(inner_start_cap_points.items[inner_start_cap_points.items.len - 1 - k]);
    }

    try self.result_polygon.finalize_current_contour();

    // Clear temporary buffers for the next path
    self.current_outer_segment_points.clearAndFree();
    self.current_inner_segment_points.clearAndFree();
    self.clockwise_ = null;
}

pub fn plotClosedJoined(
    T: type,
    self: *T,
    initial0: Point, // Logical start point of the path
    initial1: Point, // Point after initial0
    p1: Point, // Second to last point in path buffer
    p2: Point, // Last point in path buffer
) Error!void {
    // A closed path should result in two separate contours for tessellation:
    // one for the outer boundary, and one for the inner boundary.

    // First, complete the joins to ensure all points are in `current_outer_segment_points` and `current_inner_segment_points`.
    // The `p2.equal(initial0)` check determines if the last segment effectively closes to the first point.
    if (!p2.equal(initial0)) {
        // Normal case: do the final join to close the path
        try join(T, self, self.opts.join_mode, p1, p2, initial0);
        try join(T, self, self.opts.join_mode, p2, initial0, initial1);
    } else {
        // Degenerate case: last point is already initial point
        try join(T, self, self.opts.join_mode, p1, initial0, initial1);
    }

    // Now, `current_outer_segment_points` and `current_inner_segment_points` should contain
    // the complete sets of points for the outer and inner contours of the closed stroke.

    // Add outer contour to result_polygon
    try self.result_polygon.finalize_current_contour(); // Start new contour
    for (self.current_outer_segment_points.items) |p| {
        try self.result_polygon.append_point(p);
    }
    try self.result_polygon.finalize_current_contour(); // Finalize outer contour

    // Add inner contour to result_polygon
    try self.result_polygon.finalize_current_contour(); // Start new contour
    for (self.current_inner_segment_points.items) |p| {
        try self.result_polygon.append_point(p);
    }
    try self.result_polygon.finalize_current_contour(); // Finalize inner contour

    // Clear temporary buffers
    self.current_outer_segment_points.clearAndFree();
    self.current_inner_segment_points.clearAndFree();
    self.clockwise_ = null;
}

pub fn join(
    T: type,
    self: *T,
    join_mode: options.JoinMode,
    p0: Point,
    p1: Point,
    p2: Point,
) mem.Allocator.Error!void { // Removed `before_outer`
    const Joiner = WgpuJoiner; // Use the adapted Joiner

    // Guard against no-op joins - if one of our segments is degenerate, just return.
    if (p0.equal(p1) or p1.equal(p2)) {
        if (self.clockwise_ == null) self.clockwise_ = false; // Original had this
        return;
    }

    const in_face = Face.init(p0, p1, self.opts.thickness, self.opts.ctm);
    const out_face = Face.init(p1, p2, self.opts.thickness, self.opts.ctm);
    const join_clockwise = in_face.dev_slope.compare(out_face.dev_slope) < 0;

    const poly_clockwise = if (self.clockwise_) |cw| cw else join_clockwise;
    const direction_switched: bool = join_clockwise != poly_clockwise;

    const outer_joiner: Joiner = if (direction_switched) .{
        .plotter = self,
        .plot_fn = Joiner.plotInner, // Plot to inner buffer if direction switched
    } else .{
        .plotter = self,
        .plot_fn = Joiner.plotOuter, // Plot to outer buffer otherwise
    };
    const inner_joiner: Joiner = if (direction_switched) .{
        .plotter = self,
        .plot_fn = Joiner.plotOuter, // Plot to outer buffer if direction switched
    } else .{
        .plotter = self,
        .plot_fn = Joiner.plotInner, // Plot to inner buffer otherwise
    };

    // If our slopes are equal (co-linear), only plot the end of the inbound face, regardless of join mode.
    if (in_face.dev_slope.compare(out_face.dev_slope) == 0) {
        try outer_joiner.plot(
            if (join_clockwise) in_face.p1_ccw else in_face.p1_cw,
        );
        try inner_joiner.plot(
            if (join_clockwise) in_face.p1_cw else in_face.p1_ccw,
        );
        if (self.clockwise_ == null) self.clockwise_ = poly_clockwise;
        return;
    }

    switch (join_mode) {
        .miter, .bevel => {
            if (join_mode == .miter and
                Slope.compare_for_miter_limit(in_face.dev_slope, out_face.dev_slope, self.opts.miter_limit))
            {
                try outer_joiner.plot(in_face.intersect(out_face, join_clockwise));
            } else {
                try outer_joiner.plot(
                    if (join_clockwise) in_face.p1_ccw else in_face.p1_cw,
                );
                try outer_joiner.plot(
                    if (join_clockwise) out_face.p0_ccw else out_face.p0_cw,
                );
            }
        },

        .round => {
            debug.assert(self.pen != null);
            var vit = self.pen.?.vertexIteratorFor(in_face.dev_slope, out_face.dev_slope, join_clockwise);
            try outer_joiner.plot(
                if (join_clockwise) in_face.p1_ccw else in_face.p1_cw,
            );
            while (vit.next()) |v| {
                try outer_joiner.plot(
                    .{
                        .x = p1.x + v.point.x,
                        .y = p1.y + v.point.y,
                    },
                );
            }
            try outer_joiner.plot(
                if (join_clockwise) out_face.p0_ccw else out_face.p0_cw,
            );
        },
    }

    // Inner join. We plot our ends depending on direction, going through the midpoint.
    try inner_joiner.plot(if (join_clockwise) in_face.p1_cw else in_face.p1_ccw);
    try inner_joiner.plot(p1); // The actual "center" point of the join
    try inner_joiner.plot(if (join_clockwise) out_face.p0_cw else out_face.p0_ccw);

    if (self.clockwise_ == null) self.clockwise_ = poly_clockwise;
}
