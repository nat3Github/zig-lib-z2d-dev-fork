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

const DashedPlotter = struct { // Renamed Plotter to DashedPlotter
    const InitialPolygon = struct {
        alloc: mem.Allocator,
        opts: *const PlotterOptions,
        pen: ?Pen,
        points: std.ArrayList(Point), // Changed from PointBuffer to std.ArrayList(Point)
        clockwise_: ?bool,
        // Removed result, outer, inner as they are not needed here directly
        // Instead, we'll store the accumulated segment points
        initial_outer_segment_points: std.ArrayList(Point),
        initial_inner_segment_points: std.ArrayList(Point),
        current_slope: Slope,

        pub fn deinit(self: *@This()) void {
            self.points.deinit(); // Deinit ArrayList
            self.initial_outer_segment_points.deinit();
            self.initial_inner_segment_points.deinit();
        }
    };

    alloc: mem.Allocator,
    nodes: []const nodepkg.PathNode,
    opts: *const PlotterOptions,

    pen: ?Pen, // pen (lazy-initialized)

    points: std.ArrayList(Point), // Changed from PointBuffer to std.ArrayList(Point)
    clockwise_: ?bool = null, // clockwise state

    result_polygon: WgpuPolygon, // Changed from result: Polygon
    current_outer_segment_points: std.ArrayList(Point), // Replaced outer: Polygon.Contour
    current_inner_segment_points: std.ArrayList(Point), // Replaced inner: Polygon.Contour

    dasher: Dasher,
    current_slope: Slope = undefined, // normalized current device slope (see _lineTo)
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
        self.points.clearAndFree(); // Use clearAndFree for ArrayList
        try self.points.append(node.point); // Use append for ArrayList
    }

    fn runLineTo(self: *DashedPlotter, node: nodepkg.PathLineTo) Error!void {
        return self._runLineTo(self.opts.join_mode, node);
    }

    fn _runLineTo(
        self: *DashedPlotter,
        join_mode: options.JoinMode,
        node: nodepkg.PathLineTo,
    ) Error!void {
        const current_point = self.points.items[self.points.items.len - 1]; // Direct access for ArrayList
        if (node.point.equal(current_point)) {
            // consume degenerate nodes
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
            if (!current_dash_point.equal(self.points.items[self.points.items.len - 1])) { // Direct access
                // Only add this point if it's different than the point
                // before it, this allows us to plot dots (and squares
                // also), i.e., zero-length dash stops.
                try self.points.append(current_dash_point); // Use append
            }
            if (self.dasher.on) {
                if (self.points.items.len >= 2) { // Changed to >= 2 for correct join logic
                    // The original code had `> 2` here, which means it would only
                    // join after 3 points. For a segment, we need at least 2 points
                    // to determine a previous segment for joining when len is 3.
                    // The `join` function requires 3 points (p0, p1, p2).
                    // If points.len is 2, it's a single segment, no join is needed yet.
                    // If points.len is 3, we have p0, p1, p2, so we can join p0-p1 to p1-p2.
                    // The `plotOpenJoined` handles the overall segment.
                    if (self.points.items.len > 2) { // Still check > 2 for join to ensure 3 points are available
                        try join(
                            DashedPlotter,
                            self,
                            join_mode,
                            self.points.items[self.points.items.len - 3], // Direct access
                            self.points.items[self.points.items.len - 2], // Direct access
                            self.points.items[self.points.items.len - 1], // Direct access
                        );
                    }
                }
            }
            if (self.dasher.step(step_len)) {
                try self.nextSegment(current_dash_point);
            }
        }
    }

    fn runCurveTo(self: *DashedPlotter, node: nodepkg.PathCurveTo) Error!void {
        const current_point = self.points.items[self.points.items.len - 1]; // Direct access
        // Lazy-init the pen if it has not been initialized. It
        // does not need to be de-initialized here (nor should it),
        // deinit on the plotter will take care of it.
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
        if (self.points.items.len <= 0) return InternalError.InvalidState; // Check items.len
        // Unlike non-dashed close_path, we need to dash to our initial
        // point to ensure that any dashes inbetween are taken care of.
        try self._runLineTo(self.opts.join_mode, .{
            .point = switch (self.initial_polygon) {
                .on => |poly| pt: {
                    break :pt poly.points.items[0]; // Direct access
                },
                .off => |initial_point| initial_point,
                else => self.points.items[0], // Direct access (Already validated above)
            },
        });
        // How we close now depends on whether or not we actually dashed.
        switch (self.initial_polygon) {
            .on => |poly_state| { // Renamed 'poly' to 'poly_state' for consistency
                // Check the current dasher state
                if (self.dasher.on and self.points.items.len > 1) { // Check items.len
                    debug.assert(poly_state.points.items.len > 0); // Check items.len
                    if (poly_state.points.items.len == 1) { // Check items.len
                        // Our initial polygon was a dot (zero-length dash).
                        // Since we actually have already plotted back to our
                        // original point, we can just treat this as a
                        // last-segment dash off our current state.
                        try plotOpenJoined(
                            DashedPlotter,
                            self,
                            self.points.items[0], // Direct access
                            self.points.items[1], // Direct access
                            self.points.items[self.points.items.len - 2], // Direct access
                            self.points.items[self.points.items.len - 1], // Direct access
                        );
                        // Reset the initial state since we're not invoking
                        // a helper that does it.
                        self.initial_polygon = .{ .none = {} };
                    } else {
                        try self.joinAndCapInitial();
                    }
                } else {
                    // We're off, or we just transitioned to an on segment at
                    // exactly the original point, so cap off the initial using
                    // the original initial points.
                    switch (poly_state.points.items.len) { // Check items.len
                        0 => return InternalError.InvalidState,
                        1 => try self.finishInitialDotted(), // Zero-length dash, plot a dot
                        else => try self.finishInitial(
                            poly_state.points.items[0], // Direct access
                            poly_state.points.items[1], // Direct access
                        ),
                    }
                }
            },
            .off => {
                // Nothing - we've already drawn back to the initial point.
                // Just reset the initial polygon state.
                self.initial_polygon = .{ .none = {} };
            },
            .none => {
                // We never actually transitioned off the initial dash segment.
                // This almost acts like an undashed closed path, but since
                // we've already advanced to our end point in the above line_to
                // call, we need to act accordingly.
                switch (self.points.items.len) { // Check items.len
                    0 => unreachable,
                    1 => try self.plotDotted(self.points.items[0], self.current_slope), // Direct access
                    2 => try plotSingle(
                        DashedPlotter,
                        self,
                        self.points.items[0], // Direct access
                        self.points.items[1], // Direct access
                    ),
                    else => {
                        // We only need to plot the final join here, since
                        // we've already plotted the first.
                        //
                        // Join around the initial point
                        const initial_point = self.points.items[0];
                        const second_point = self.points.items[1];
                        const last_point = self.points.items[self.points.items.len - 1];
                        const second_to_last_point = self.points.items[self.points.items.len - 2];

                        try plotClosedJoined( // Use plotClosedJoined
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
        self.points.clearAndFree(); // Use clearAndFree for ArrayList
    }

    // New helper function to finalize the current segment and add to result_polygon
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
            if (self.points.items.len == 1) { // Check items.len
                try self.plotDotted(self.points.items[0], self.current_slope); // Direct access
            } else if (self.points.items.len >= 2) { // Changed to >= 2 to cover both 2 and >2 cases
                if (self.points.items.len == 2) {
                    try plotSingle(
                        DashedPlotter,
                        self,
                        self.points.items[0], // Direct access
                        self.points.items[1], // Direct access
                    );
                } else { // self.points.items.len > 2
                    try plotOpenJoined(
                        DashedPlotter,
                        self,
                        self.points.items[0], // Direct access
                        self.points.items[1], // Direct access
                        self.points.items[self.points.items.len - 2], // Direct access
                        self.points.items[self.points.items.len - 1], // Direct access
                    );
                }
            }
            self.current_outer_segment_points.clearRetainingCapacity();
            self.current_inner_segment_points.clearRetainingCapacity();
        }
        self.points.clearAndFree(); // Use clearAndFree for ArrayList
        try self.points.append(point); // Use append for ArrayList
    }

    fn finish(self: *DashedPlotter) Error!void {
        switch (self.initial_polygon) {
            .on => |poly_state| { // Renamed 'poly' to 'poly_state'
                switch (poly_state.points.items.len) { // Check items.len
                    0 => return InternalError.InvalidState,
                    1 => try self.finishInitialDotted(),
                    else => try self.finishInitial(
                        poly_state.points.items[0], // Direct access
                        poly_state.points.items[1], // Direct access
                    ),
                }
            },
            .off => self.initial_polygon = .{ .none = {} },
            .none => {},
        }
        if (self.dasher.on) {
            if (self.points.items.len == 1) { // Check items.len
                try self.plotDotted(self.points.items[0], self.current_slope); // Direct access
            } else if (self.points.items.len >= 2) { // Changed to >= 2
                if (self.points.items.len == 2) {
                    try plotSingle(
                        DashedPlotter,
                        self,
                        self.points.items[0], // Direct access
                        self.points.items[1], // Direct access
                    );
                } else { // self.points.items.len > 2
                    try plotOpenJoined(
                        DashedPlotter,
                        self,
                        self.points.items[0], // Direct access
                        self.points.items[1], // Direct access
                        self.points.items[self.points.items.len - 2], // Direct access
                        self.points.items[self.points.items.len - 1], // Direct access
                    );
                }
            }
            self.current_outer_segment_points.clearRetainingCapacity();
            self.current_inner_segment_points.clearRetainingCapacity();
        }
    }

    fn plotDotted(self: *DashedPlotter, point: Point, current_slope: Slope) Error!void {
        // Closed degenerate line of a length == 0. This is handled in special
        // cases:
        //
        // * When the cap style is round, we draw a circle around the point (as
        // if both ends were round-capped).
        //
        // * When the cap style is square, and we are in an "on" segment in a
        // dashed stroke, we draw a square, oriented in the direction of the
        // stroke.
        //
        // All other zero-length strokes draw nothing.
        // debug.assert(self.inner.corners.len == 0); // Removed assertion, inner is ArrayList now
        switch (self.opts.cap_mode) {
            .round => {
                // Just plot off all of the pen's vertices, no need to
                // determine a subset as we're doing a 360-degree plot.
                debug.assert(self.pen != null);
                try self.result_polygon.finalize_current_contour(); // Use WgpuPolygon method
                for (self.pen.?.vertices.items) |v| {
                    try self.result_polygon.append_point( // Use WgpuPolygon method
                        .{
                            .x = point.x + v.point.x,
                            .y = point.y + v.point.y,
                        },
                    );
                }
                try self.result_polygon.finalize_current_contour(); // Use WgpuPolygon method
            },
            .square => {
                // "cap" a single point with the last slope we've logged in
                // a line_to or close_path. We just take a subset of
                // capSquare in Face, while still computing the offsets
                // using some of the init functionality.
                //
                // TODO: This (honestly, along with Face in general) is due
                // for a refactor so that we can de-atomize some of the
                // more common functionality here. There's currently only a
                // few wasted ops _maybe_ (additions on the extra point
                // that are not needed), but it would be nice to be able to
                // be confident and be able to say that there's no risk of
                // any due to over-abstraction and code re-use.
                const face = Face.initSingle(
                    point,
                    current_slope,
                    self.opts.thickness,
                    self.opts.ctm,
                );
                var offset_x = face.user_slope.dx * face.half_width;
                var offset_y = face.user_slope.dy * face.half_width;
                self.opts.ctm.userToDeviceDistance(&offset_x, &offset_y);

                try self.result_polygon.finalize_current_contour(); // Use WgpuPolygon method
                try self.result_polygon.append_point( // Use WgpuPolygon method
                    .{
                        .x = face.p1_cw.x - offset_x,
                        .y = face.p1_cw.y - offset_y,
                    },
                );
                try self.result_polygon.append_point( // Use WgpuPolygon method
                    .{
                        .x = face.p1_cw.x + offset_x,
                        .y = face.p1_cw.y + offset_y,
                    },
                );
                try self.result_polygon.append_point( // Use WgpuPolygon method
                    .{
                        .x = face.p1_ccw.x + offset_x,
                        .y = face.p1_ccw.y + offset_y,
                    },
                );
                try self.result_polygon.append_point( // Use WgpuPolygon method
                    .{
                        .x = face.p1_ccw.x - offset_x,
                        .y = face.p1_ccw.y - offset_y,
                    },
                );

                try self.result_polygon.finalize_current_contour(); // Use WgpuPolygon method
            },
            else => {},
        }
        // Reset outer, de-allocating our contour that has been recorded as
        // edges and resetting state.
        // Removed self.outer.deinit(self.alloc); and self.outer = .{ .scale = self.opts.scale };
        self.clockwise_ = null;
    }

    fn saveInitial(
        self: *DashedPlotter,
    ) void {
        // This prepares the initial polygon for later capping or joining,
        // depending on the final state of the stroke. The thing is that we
        // don't necessarily know if we're dealing with a close_path or
        // not, and if the stroker state will be on or not in that close.
        // So this tracks as much state as we need to make a decision at
        // that point.
        if (!self.dasher.on) {
            // This is intended to be used on dash step transitions, so we
            // save if the dasher state was off.
            //
            // Note that there are some duplication of fields from the plotter
            // here (alloc, options, pen) to ensure that we can just use the
            // initial polygon with our generic plotting helpers (join and
            // plotOpenJoined). This should be of no concern and minimal
            // overhead (allocator and opts are just pointers, and the pen
            // solely contains an ArrayListUnmanaged so is not much more than
            // that). The only possible concern is the fact that the pen is
            // lazy-initialized and could be done so later than the initial
            // polygon in a curve_to. However, in that case, it's only used for
            // round-joining the decomposed lines and as such would not be
            // needed for joining or capping anything connecting to the initial
            // polygons anyway.
            self.initial_polygon = .{
                .on = .{
                    .alloc = self.alloc,
                    .opts = self.opts,
                    .pen = self.pen,
                    .points = self.points, // Transfer ownership
                    .clockwise_ = self.clockwise_,
                    // Store the current segment points for later use
                    .initial_outer_segment_points = self.current_outer_segment_points,
                    .initial_inner_segment_points = self.current_inner_segment_points,
                    .current_slope = self.current_slope,
                },
            };
            // Re-initialize self's ArrayLists after transferring ownership
            self.points = std.ArrayList(Point).init(self.alloc);
            self.current_outer_segment_points = std.ArrayList(Point).init(self.alloc);
            self.current_inner_segment_points = std.ArrayList(Point).init(self.alloc);
        } else {
            // We record that the initial dash state was off and discard
            // any data in the off segment, minus the initial point, which
            // we need for a possible close_path in the sub-path we're
            // currently in. This can happen when dash offsets have
            // pushed/pulled the state into an off segment at the start of
            // the stroke.
            debug.assert(self.points.items.len > 0); // Check items.len
            self.initial_polygon = .{ .off = self.points.items[0] }; // Direct access
        }

        // Reset the contours, and clockwise state. As our corner data has been
        // off-loaded to the initial polygon, no deinit is necessary on either
        // contour.
        // Removed self.outer = .{ .scale = self.opts.scale }; and self.inner = .{ .scale = self.opts.scale };
        self.points.clearAndFree(); // Ensure it's empty after saving/transferring
        self.clockwise_ = null;
    }

    fn finishInitialDotted(
        self: *DashedPlotter,
    ) Error!void {
        if (self.initial_polygon != .on) return InternalError.InvalidState;
        var initial_poly_state = self.initial_polygon.on; // Get mutable reference
        try self.plotDotted(
            initial_poly_state.points.items[0], // Direct access
            initial_poly_state.current_slope,
        );
        initial_poly_state.deinit(); // Deinit the InitialPolygon state
        self.initial_polygon = .{ .none = {} };
    }

    fn finishInitial(
        self: *DashedPlotter,
        _: Point,
        _: Point,
    ) Error!void {
        if (self.initial_polygon != .on) return InternalError.InvalidState;
        var initial_poly_state = self.initial_polygon.on; // Get mutable reference

        // Create a temporary plotter context that mimics DashedPlotter's required fields
        // so that plotOpenJoined can operate on the initial_poly_state's data.
        var temp_plotter_ctx: struct {
            result_polygon: *WgpuPolygon,
            current_outer_segment_points: std.ArrayList(Point),
            current_inner_segment_points: std.ArrayList(Point),
            opts: *const PlotterOptions,
            pen: ?Pen,
            clockwise_: ?bool,
            alloc: mem.Allocator,
        } = .{
            .result_polygon = &self.result_polygon, // Use the main plotter's result_polygon
            .current_outer_segment_points = initial_poly_state.initial_outer_segment_points,
            .current_inner_segment_points = initial_poly_state.initial_inner_segment_points,
            .opts = self.opts,
            .pen = self.pen,
            .clockwise_ = self.clockwise_, // Pass current clockwise state
            .alloc = self.alloc,
        };

        try plotOpenJoined(
            @TypeOf(temp_plotter_ctx), // Pass the type of the temporary context
            &temp_plotter_ctx, // Pass a pointer to the temporary context
            initial_poly_state.points.items[0], // first point of initial path
            initial_poly_state.points.items[1], // second point of initial path
            initial_poly_state.points.items[initial_poly_state.points.items.len - 2], // second to last point of initial path
            initial_poly_state.points.items[initial_poly_state.points.items.len - 1], // last point of initial path
        );
        // Note that our generic plotOpenJoined within stroke_plotter.zig will
        // properly deinit our contour state within our initial polygon, so all
        // we need to do here is change the initial polygon state back to
        // .none.
        initial_poly_state.deinit(); // Deinit the InitialPolygon state
        self.initial_polygon = .{ .none = {} };
    }

    fn joinAndCapInitial(self: *DashedPlotter) Error!void {
        // This adds a join at the beginning of the initial polygon before
        // capping.
        if (self.initial_polygon != .on) return InternalError.InvalidState;
        var initial_poly_state = self.initial_polygon.on; // Get mutable reference

        // Create a temporary plotter context for the initial_poly_state's data
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

        if (self.points.items.len > 2) { // Check items.len
            // Do the final join on the existing polygon.
            try join(
                DashedPlotter, // Use DashedPlotter type for the main plotter
                self, // Pass the main plotter instance
                self.opts.join_mode,
                self.points.items[self.points.items.len - 3], // Direct access
                self.points.items[self.points.items.len - 2], // Direct access
                initial_poly_state.points.items[0], // Direct access
            );

            // Concat the initial polygon's segments to the current segments
            try self.current_outer_segment_points.appendSlice(temp_initial_ctx.current_outer_segment_points.items);
            try self.current_inner_segment_points.appendSlice(temp_initial_ctx.current_inner_segment_points.items);

            // Our first cap points are based entirely off of the plotter state
            // (not the initial state).
            try plotClosedJoined( // Use plotClosedJoined for a closed path
                DashedPlotter,
                self,
                self.points.items[0], // First point of current segment
                self.points.items[1], // Second point of current segment
                initial_poly_state.points.items[initial_poly_state.points.items.len - 2], // Second to last point of initial path
                initial_poly_state.points.items[initial_poly_state.points.items.len - 1], // Last point of initial path
            );
        } else {
            // Don't need to do any concats and our cap points are last corner
            // -> start of initial polygon.

            // Do the join
            try join(
                DashedPlotter, // Use DashedPlotter type for the main plotter
                self, // Pass the main plotter instance
                self.opts.join_mode,
                self.points.items[0], // Direct access (p0)
                self.points.items[1], // Direct access (p1)
                initial_poly_state.points.items[0], // Direct access (p2 - initial point)
            );

            try plotClosedJoined( // Use plotClosedJoined
                DashedPlotter,
                self,
                self.points.items[0], // First point of current segment
                initial_poly_state.points.items[0], // First point of initial path
                initial_poly_state.points.items[initial_poly_state.points.items.len - 2], // Second to last point of initial path
                initial_poly_state.points.items[initial_poly_state.points.items.len - 1], // Last point of initial path
            );
        }

        initial_poly_state.deinit(); // Deinit the InitialPolygon state
        self.initial_polygon = .{ .none = {} };
        // Reset the main polygon state as we don't do that above (the initial
        // gets cleared instead). Note that we don't need to de-init any
        // corners here, as either they are all in the initial polygon (in the
        // simple case where there were no outstanding joins), or were moved
        // there (in the more complex case where there were).
        self.current_outer_segment_points.clearRetainingCapacity(); // Clear the main plotter's segments
        self.current_inner_segment_points.clearRetainingCapacity(); // Clear the main plotter's segments
        self.clockwise_ = null;
    }

    const CurveToCtx = struct {
        plotter: *DashedPlotter, // Changed to DashedPlotter

        fn line_to(ctx: *anyopaque, err_: *?PlotterVTable.Error, node: nodepkg.PathLineTo) void {
            const self: *CurveToCtx = @ptrCast(@alignCast(ctx));
            self.plotter._runLineTo(.round, node) catch |err| {
                err_.* = err;
            };
        }
    };
};
