// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi

//! Contains unmanaged painter functions for filling and stroking.

const wgpu = @import("wgpu");
const libtess = @import("libtess").c;
const libtess_util = @import("libtess").util;
const z2d = @import("z2d");
const std = @import("std");
const debug = @import("std").debug;
const heap = @import("std").heap;
const math = @import("std").math;
const mem = @import("std").mem;
const testing = @import("std").testing;

const options = z2d.options;
const pixel = z2d.pixel;
const Context = z2d.Context;
const Path = z2d.Path;
const PathNode = Path.PathNode;
const Surface = z2d.Surface;
const Pattern = z2d.Pattern;
const Transformation = z2d.Transformation;
const compositor = z2d.compositor;
const Point = @import("internal/Point.zig");
const og_painter = @import("painter.zig");
const FillOpts = og_painter.FillOpts;
const StrokeOpts = og_painter.StrokeOpts;
const Spline = @import("internal/Spline.zig");
const PlotterVTable = @import("internal/PlotterVTable.zig");
const InternalError = @import("internal/InternalError.zig").InternalError;
const WgpuPolygon = @import("internal/wgpu_Polygon.zig");
const Range = WgpuPolygon.Range;
const PointF32 = WgpuPolygon.PointF32;
const fill_plotter = @import("internal/fill_plotter.zig");
const stroke_plotter = @import("internal/stroke_plotter.zig");

const Renderer = struct {
    alloc: mem.Allocator,
    arena: std.heap.ArenaAllocator,
    batch_vertices: BatchTriangleVertices,
    batch_indexes: BatchTriangleIndices,
    pub fn add_tesselated_triangles_to_batch(self: *@This(), tess: *libtess.TESStesselator, pattern: *const Pattern) void {
        const triangle_count = libtess.tessGetElementCount(tess);
        const vertices_pointer: [*]const PointF32 = @ptrCast(libtess.tessGetVertices(tess));
        var vertices: []const PointF32 = undefined;
        vertices.ptr = vertices_pointer;
        vertices.len = libtess.tessGetVertexCount(tess);
        for (vertices) |v| {
            const color = pattern.getPixel(@intFromFloat(v.x), @intFromFloat(v.y));
            self.batch_vertices.append(v, color);
        }
        self.batch_vertices.finalize();
        var index_slices: []c_int = undefined;
        index_slices.ptr = libtess.tessGetVertexIndices(tess);
        index_slices.len = triangle_count * 3;
        for (index_slices) |idx| {
            self.batch_indexes.append(idx);
        }
        self.batch_indexes.finalize();
        std.log.warn("produced {} triangles", .{triangle_count});
    }

    pub fn fill(
        self: *Renderer,
        pattern: *const Pattern,
        nodes: []const PathNode,
        opts: FillOpts,
    ) !void {
        if (nodes.len == 0) return;
        if (!PathNode.isClosedNodeSet(nodes)) return error.PathNotClosed;
        const alloc = self.arena.allocator();
        defer _ = self.arena.reset(.retain_capacity);
        const polygons = try fill_plotter.plot(alloc, nodes, @max(opts.tolerance, 0.001));
        var tess_alloc = libtess_util.tess_alloc_from(&alloc);
        const tess = libtess.tessNewTess(&tess_alloc) orelse return InternalError.InvalidState;
        const points = polygons.vertex_points.items;
        for (polygons.range) |range| {
            const slice = points[range.start..range.end];
            const ptr: *anyopaque = @alignCast(@ptrCast(slice.ptr));
            libtess.tessAddContour(tess, 2, ptr, @sizeOf(PointF32), points.len);
        }
        const tess_winding = switch (opts.fill_rule) {
            .even_odd => libtess.TESS_WINDING_ODD,
            .non_zero => libtess.TESS_WINDING_NONZERO,
        };
        const res = libtess.tessTesselate(tess, tess_winding, libtess.TESS_POLYGONS, 3, 2, null);
        if (res != 1) return error.TesselateFailed;
        self.add_tesselated_triangles_to_batch(tess, pattern);
    }

    pub fn stroke(
        self: *Renderer,
        pattern: *const Pattern,
        nodes: []const PathNode,
        opts: StrokeOpts,
    ) !void {
        _ = try opts.transformation.inverse();
        if (nodes.len == 0) return;
        const minimum_line_width: f64 = 0.00390625;
        const alloc = self.arena.allocator();
        defer _ = self.arena.reset(.retain_capacity);
        const cap_mode: options.CapMode = if (opts.line_width >= 2) opts.line_cap_mode else .butt;
        const ctm: Transformation = opts.transformation;
        const dashes: []const f64 = opts.dashes;
        const dash_offset: f64 = opts.dash_offset;
        const join_mode: options.JoinMode = if (opts.line_width >= 2) opts.line_join_mode else .miter;
        const miter_limit: f64 = if (opts.line_width >= 2) opts.miter_limit else 10.0;
        const thickness: f64 = if (opts.line_width >= minimum_line_width) opts.line_width else minimum_line_width;
        const tolerance: f64 = @max(opts.tolerance, 0.001);

        const polygons = try stroke_plotter.plot(alloc, nodes, .{
            .cap_mode = cap_mode,
            .ctm = ctm,
            .dash_offset = dash_offset,
            .dashes = dashes,
            .join_mode = join_mode,
            .miter_limit = miter_limit,
            .scale = 1,
            .thickness = thickness,
            .tolerance = tolerance,
        });

        var tess_alloc = libtess_util.tess_alloc_from(&alloc);
        const tess = libtess.tessNewTess(&tess_alloc) orelse return InternalError.InvalidState;
        const points = polygons.vertex_points.items;
        for (polygons.range) |range| {
            const slice = points[range.start..range.end];
            const ptr: *anyopaque = @alignCast(@ptrCast(slice.ptr));
            libtess.tessAddContour(tess, 2, ptr, @sizeOf(PointF32), points.len);
        }
        const tess_winding = switch (opts.fill_rule) {
            .even_odd => libtess.TESS_WINDING_ODD,
            .non_zero => libtess.TESS_WINDING_NONZERO,
        };
        const res = libtess.tessTesselate(tess, tess_winding, libtess.TESS_POLYGONS, 3, 2, null);
        if (res != 1) return error.TesselateFailed;
        self.add_tesselated_triangles_to_batch(tess, pattern);
    }
};

const BatchTriangleIndices = struct {
    indices: std.ArrayList(u32),
    range: std.ArrayList(Range),
    range_start_idx: usize = 0,
    pub fn init(gpa: std.mem.Allocator) BatchTriangleIndices {
        return .{
            .triangle_indices = std.ArrayList(u32).init(gpa),
            .range = std.ArrayList(Range).init(gpa),
        };
    }
    pub fn deinit(self: *@This()) void {
        self.range.deinit();
        self.indices.deinit();
    }
    pub fn append(self: *@This(), index: u32) !void {
        try self.indices.append(index);
    }
    pub fn finalize(self: *@This()) !void {
        const current_end_idx = self.vertex_points.items.len;
        if (self.current_len() > 0) {
            try self.range.append(.{
                .start = self.range_start_idx,
                .end = current_end_idx,
            });
        }
        self.range_start_idx = current_end_idx;
    }
};

const BatchTriangleVertices = struct {
    const Color4U8 = [4]u8;
    vertex_points: std.ArrayList(PointF32),
    vertex_colors: std.ArrayList(Color4U8),
    range: std.ArrayList(Range),
    range_start_idx: usize = 0,
    pub fn init(gpa: std.mem.Allocator) @This() {
        return .{
            .vertex_points = std.ArrayList(PointF32).init(gpa),
            .vertex_colors = std.ArrayList(Color4U8).init(gpa),
            .range = std.ArrayList(Range).init(gpa),
        };
    }
    pub fn deinit(self: *@This()) void {
        self.range.deinit();
        self.vertex_points.deinit();
        self.vertex_colors.deinit();
    }
    pub fn append(self: *@This(), point: PointF32, color: [4]u8) !void {
        try self.vertex_points.append(point);
        try self.vertex_colors.append(color);
    }
    pub fn finalize(self: *@This()) !void {
        const current_end_idx = self.vertex_points.items.len;
        if (self.current_len() > 0) {
            try self.range.append(.{
                .start = self.range_start_idx,
                .end = current_end_idx,
            });
        }
        self.range_start_idx = current_end_idx;
    }
};
