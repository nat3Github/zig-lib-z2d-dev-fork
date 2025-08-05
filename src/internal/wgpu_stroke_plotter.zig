// stroke_plotter.zig

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
const WgpuPolygon = @import("wgpu_Polygon.zig");
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
    scale: f64,
    thickness: f64,
    tolerance: f64,
};

pub fn plot(
    alloc: mem.Allocator,
    nodes: []const nodepkg.PathNode,
    opts: PlotterOptions,
) Error!WgpuPolygon {
    if (Dasher.validate(opts.dashes)) {
        unreachable;
    }

    var plotter = try Plotter.init(alloc, &opts);
    plotter.nodes = nodes;

    errdefer plotter.deinit();
    defer if (plotter.pen) |*p| p.deinit(alloc);

    try plotter.run();

    return plotter.result_polygon;
}

const Plotter = struct {
    alloc: mem.Allocator,
    nodes: []const nodepkg.PathNode,
    opts: *const PlotterOptions,

    pen: ?Pen,

    points: PointBuffer = .{},
    clockwise_: ?bool = null,

    current_outer_segment_points: std.ArrayList(Point),
    current_inner_segment_points: std.ArrayList(Point),

    result_polygon: WgpuPolygon,

    current_logical_path_start_point: ?Point = null,

    pub fn init(alloc: mem.Allocator, opts: *const PlotterOptions) Error!@This() {
        var initialized_pen: ?Pen = null;
        if (opts.cap_mode == .round or opts.join_mode == .round) {
            initialized_pen = try Pen.init(
                alloc,
                opts.thickness,
                opts.tolerance,
                opts.ctm,
            );
        }
        return .{
            .alloc = alloc,
            .nodes = &.{},
            .opts = opts,
            .pen = initialized_pen,
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
            try self.finish();
        }
        self.points.reset();
        self.points.add(node.point);
        self.current_logical_path_start_point = node.point;

        self.current_outer_segment_points.clearAndFree();
        self.current_inner_segment_points.clearAndFree();
    }

    fn runLineTo(self: *Plotter, node: nodepkg.PathLineTo) Error!void {
        try self._runLineTo(self.opts.join_mode, node);
    }

    fn _runLineTo(self: *Plotter, join_mode: options.JoinMode, node: nodepkg.PathLineTo) Error!void {
        const current_point = self.points.last() orelse return InternalError.InvalidState;
        if (node.point.equal(current_point)) {
            return;
        }
        self.points.add(node.point);

        if (self.points.len >= 3) {
            try join(
                @This(),
                self,
                join_mode,
                self.points.tail(3) orelse unreachable,
                self.points.tail(2) orelse unreachable,
                self.points.tail(1) orelse unreachable,
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
                    initial_point,
                    self.points.head(1) orelse unreachable,
                    self.points.tail(2) orelse unreachable,
                    self.points.tail(1) orelse unreachable,
                );
            },
        }
        self.points.reset();
        self.clockwise_ = null;
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
        self.clockwise_ = null;
    }

    fn plotDotted(self: *Plotter, point: Point) Error!void {
        debug.assert(self.current_inner_segment_points.items.len == 0);
        if (self.opts.cap_mode == .round) {
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

const CapPlotterCtx = struct {
    alloc: mem.Allocator,
    contour_points: *std.ArrayList(Point),
    fn line_to(ctx: *anyopaque, err_: *?PlotterVTable.Error, node: nodepkg.PathLineTo) void {
        const self: *CapPlotterCtx = @ptrCast(@alignCast(ctx));
        self.contour_points.append(node.point) catch |err| {
            err_.* = err;
            return;
        };
    }
};

const WgpuJoiner = struct {
    const Self = @This();
    plotter: *Plotter,

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
    debug.assert(self.current_inner_segment_points.items.len == 0);

    const face = Face.init(
        start,
        end,
        self.opts.thickness,
        self.opts.ctm,
    );

    try self.result_polygon.finalize_current_contour();

    var outer_points = std.ArrayList(Point).init(self.alloc);
    defer outer_points.deinit();
    var inner_points = std.ArrayList(Point).init(self.alloc);
    defer inner_points.deinit();

    var outer_cap_ctx: CapPlotterCtx = .{ .alloc = self.alloc, .contour_points = &outer_points };
    var inner_cap_ctx: CapPlotterCtx = .{ .alloc = self.alloc, .contour_points = &inner_points };

    try face.cap_p0(
        &.{ .ptr = &outer_cap_ctx, .line_to = CapPlotterCtx.line_to },
        self.opts.cap_mode,
        true,
        self.pen,
    );

    try face.cap_p1(
        &.{ .ptr = &outer_cap_ctx, .line_to = CapPlotterCtx.line_to },
        self.opts.cap_mode,
        true,
        self.pen,
    );

    try face.cap_p1(
        &.{ .ptr = &inner_cap_ctx, .line_to = CapPlotterCtx.line_to },
        self.opts.cap_mode,
        false,
        self.pen,
    );

    try face.cap_p0(
        &.{ .ptr = &inner_cap_ctx, .line_to = CapPlotterCtx.line_to },
        self.opts.cap_mode,
        false,
        self.pen,
    );

    for (outer_points.items) |p| {
        try self.result_polygon.append_point(p);
    }
    for (0..inner_points.items.len) |k| {
        try self.result_polygon.append_point(inner_points.items[inner_points.items.len - 1 - k]);
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

    try self.result_polygon.finalize_current_contour();

    var outer_start_cap_points = std.ArrayList(Point).init(self.alloc);
    defer outer_start_cap_points.deinit();
    var cap_ctx_outer_start: CapPlotterCtx = .{ .alloc = self.alloc, .contour_points = &outer_start_cap_points };
    try cap_points_start.cap_p0(
        &.{ .ptr = &cap_ctx_outer_start, .line_to = CapPlotterCtx.line_to },
        self.opts.cap_mode,
        clockwise,
        self.pen,
    );
    for (outer_start_cap_points.items) |p| {
        try self.result_polygon.append_point(p);
    }

    for (self.current_outer_segment_points.items) |p| {
        try self.result_polygon.append_point(p);
    }

    var outer_end_cap_points = std.ArrayList(Point).init(self.alloc);
    defer outer_end_cap_points.deinit();
    var cap_ctx_outer_end: CapPlotterCtx = .{ .alloc = self.alloc, .contour_points = &outer_end_cap_points };
    try cap_points_end.cap_p1(
        &.{ .ptr = &cap_ctx_outer_end, .line_to = CapPlotterCtx.line_to },
        self.opts.cap_mode,
        clockwise,
        self.pen,
    );
    for (outer_end_cap_points.items) |p| {
        try self.result_polygon.append_point(p);
    }

    var inner_end_cap_points = std.ArrayList(Point).init(self.alloc);
    defer inner_end_cap_points.deinit();
    var cap_ctx_inner_end: CapPlotterCtx = .{ .alloc = self.alloc, .contour_points = &inner_end_cap_points };
    try cap_points_end.cap_p1(
        &.{ .ptr = &cap_ctx_inner_end, .line_to = CapPlotterCtx.line_to },
        self.opts.cap_mode,
        !clockwise,
        self.pen,
    );
    for (0..inner_end_cap_points.items.len) |k| {
        try self.result_polygon.append_point(inner_end_cap_points.items[inner_end_cap_points.items.len - 1 - k]);
    }

    for (0..self.current_inner_segment_points.items.len) |k| {
        try self.result_polygon.append_point(self.current_inner_segment_points.items[self.current_inner_segment_points.items.len - 1 - k]);
    }

    var inner_start_cap_points = std.ArrayList(Point).init(self.alloc);
    defer inner_start_cap_points.deinit();
    var cap_ctx_inner_start: CapPlotterCtx = .{ .alloc = self.alloc, .contour_points = &inner_start_cap_points };
    try cap_points_start.cap_p0(
        &.{ .ptr = &cap_ctx_inner_start, .line_to = CapPlotterCtx.line_to },
        self.opts.cap_mode,
        !clockwise,
        self.pen,
    );
    for (0..inner_start_cap_points.items.len) |k| {
        try self.result_polygon.append_point(inner_start_cap_points.items[inner_start_cap_points.items.len - 1 - k]);
    }

    try self.result_polygon.finalize_current_contour();

    self.current_outer_segment_points.clearAndFree();
    self.current_inner_segment_points.clearAndFree();
    self.clockwise_ = null;
}

pub fn plotClosedJoined(
    T: type,
    self: *T,
    initial0: Point,
    initial1: Point,
    p1: Point,
    p2: Point,
) Error!void {
    if (!p2.equal(initial0)) {
        try join(T, self, self.opts.join_mode, p1, p2, initial0);
        try join(T, self, self.opts.join_mode, p2, initial0, initial1);
    } else {
        try join(T, self, self.opts.join_mode, p1, initial0, initial1);
    }

    try self.result_polygon.finalize_current_contour();
    for (self.current_outer_segment_points.items) |p| {
        try self.result_polygon.append_point(p);
    }
    try self.result_polygon.finalize_current_contour();

    try self.result_polygon.finalize_current_contour();
    // REVERSE THE INNER CONTOUR POINTS TO ENSURE OPPOSITE WINDING
    for (0..self.current_inner_segment_points.items.len) |k| {
        try self.result_polygon.append_point(self.current_inner_segment_points.items[self.current_inner_segment_points.items.len - 1 - k]);
    }
    try self.result_polygon.finalize_current_contour();

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
) mem.Allocator.Error!void {
    const Joiner = WgpuJoiner;

    if (p0.equal(p1) or p1.equal(p2)) {
        if (self.clockwise_ == null) self.clockwise_ = false;
        return;
    }

    const in_face = Face.init(p0, p1, self.opts.thickness, self.opts.ctm);
    const out_face = Face.init(p1, p2, self.opts.thickness, self.opts.ctm);
    const join_clockwise = in_face.dev_slope.compare(out_face.dev_slope) < 0;

    const poly_clockwise = if (self.clockwise_) |cw| cw else join_clockwise;
    const direction_switched: bool = join_clockwise != poly_clockwise;

    const outer_joiner: Joiner = if (direction_switched) .{
        .plotter = self,
        .plot_fn = Joiner.plotInner,
    } else .{
        .plotter = self,
        .plot_fn = Joiner.plotOuter,
    };
    const inner_joiner: Joiner = if (direction_switched) .{
        .plotter = self,
        .plot_fn = Joiner.plotOuter,
    } else .{
        .plotter = self,
        .plot_fn = Joiner.plotInner,
    };

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

    try inner_joiner.plot(if (join_clockwise) in_face.p1_cw else in_face.p1_ccw);
    try inner_joiner.plot(if (join_clockwise) out_face.p0_cw else out_face.p0_ccw);

    if (self.clockwise_ == null) self.clockwise_ = poly_clockwise;
}
