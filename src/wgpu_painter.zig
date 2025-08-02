// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi

//! Contains unmanaged painter functions for filling and stroking.
const wgpu = @import("wgpu");
const libtess = @import("libtess").c;
const libtess_util = @import("libtess").util;
const z2d = @import("z2d.zig");
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
const InternalError = @import("internal/InternalError.zig").InternalError;
const nodepkg = @import("internal/path_nodes.zig");

pub const FillOpts = struct {
    /// The anti-aliasing mode to use with the fill operation.
    anti_aliasing_mode: options.AntiAliasMode = .default,
    /// The fill rule to use during the fill operation.
    fill_rule: options.FillRule = .non_zero,
    /// The operator to use for compositing.
    operator: compositor.Operator = .src_over,
    /// The precision to use when compositing.
    precision: compositor.Precision = .integer,
    /// The maximum error tolerance used for approximating curves and arcs. A
    /// higher tolerance will give better performance, but "blockier" curves.
    /// The default tolerance should be sufficient for most cases.
    tolerance: f64 = options.default_tolerance,
};

/// Errors related to the `fill` operation.
///
/// **Note for autodoc viewers:** `std.mem.Allocator.Error` is a member of this
/// set, but is not shown because `std` is pruned from our autodoc.
pub const FillError = error{
    /// The supplied path (and any sub-paths) have not been explicitly closed,
    /// which is required by the fill operation.
    PathNotClosed,
} || Surface.Error || InternalError || mem.Allocator.Error;
pub fn fill(
    alloc: mem.Allocator,
    surface: *Surface,
    pattern: *const Pattern,
    nodes: []const PathNode,
    opts: FillOpts,
) FillError!void {
    _ = .{ surface, pattern };
    if (nodes.len == 0) return;
    if (!PathNode.isClosedNodeSet(nodes)) return error.PathNotClosed;
    var alloc_in_fn = alloc;
    var contour_list = try fill_plotter.plot(alloc, nodes, @max(opts.tolerance, 0.001));
    defer contour_list.deinit();
    var tess_alloc = libtess_util.tess_alloc_from(&alloc_in_fn);
    const tess = libtess.tessNewTess(&tess_alloc);
    defer libtess.tessDeleteTess(tess);
    if (tess == null) return InternalError.InvalidState;
    const points = contour_list.points.items;
    for (contour_list.range.items) |range| {
        const slice = points[range.start..range.end];
        const ptr: *anyopaque = @alignCast(@ptrCast(slice.ptr));
        libtess.tessAddContour(tess, 2, ptr, @sizeOf(PointF32), @intCast(points.len));
    }
    const tess_winding = switch (opts.fill_rule) {
        .even_odd => libtess.TESS_WINDING_ODD,
        .non_zero => libtess.TESS_WINDING_NONZERO,
    };
    const res = libtess.tessTesselate(tess, tess_winding, libtess.TESS_POLYGONS, 3, 2, null);
    if (res != 1) return InternalError.InvalidState;
    const pcount = libtess.tessGetElementCount(tess);
    std.log.warn("produced {} triangles", .{pcount});

    @panic("TODO: write to gpu buffer then render on the gpu");
    // TODO(nat3)implement the same thing for stroking
}

pub const StrokeOpts = struct {
    /// The anti-aliasing mode to use with the stroke operation.
    anti_aliasing_mode: options.AntiAliasMode = .default,
    /// The dash array, if dashed lines are desired. See `Context` for a full
    /// explanation of this setting.
    dashes: []const f64 = &.{},
    /// The dash offset when doing dashed lines. See `Context` for a full
    /// explanation of this setting.
    dash_offset: f64 = 0,
    /// The line cap rule for the stroke operation.
    line_cap_mode: options.CapMode = .butt,
    /// The line join style for the stroke operation.
    line_join_mode: options.JoinMode = .miter,
    /// The line width for the stroke operation.
    line_width: f64 = 2.0,
    /// The maximum allowed ratio for miter joins. See `Context` for a full
    /// explanation of this setting.
    miter_limit: f64 = 10.0,
    /// The operator to use for compositing.
    operator: compositor.Operator = .src_over,
    /// The precision to use when compositing.
    precision: compositor.Precision = .integer,
    /// The maximum error tolerance used for approximating curves and arcs. A
    /// higher tolerance will give better performance, but "blockier" curves.
    /// The default tolerance should be sufficient for most cases.
    tolerance: f64 = options.default_tolerance,
    /// The transformation matrix to use for the stroke operation. Has more
    /// subtle influences on drawing, affecting line width respective to scale,
    /// warping due to a warped scale (e.g., different x and y scale), and any
    /// respective capping.
    transformation: Transformation = Transformation.identity,
};

/// Errors related to the `stroke` operation.
///
/// **Note for autodoc viewers:** `std.mem.Allocator.Error` is a member of this
/// set, but is not shown because `std` is pruned from our autodoc.
pub const StrokeError = Transformation.Error || Surface.Error || InternalError || mem.Allocator.Error;
pub fn stroke(
    alloc: mem.Allocator,
    surface: *Surface,
    pattern: *const Pattern,
    nodes: []const PathNode,
    opts: StrokeOpts,
) StrokeError!void {
    _ = .{ surface, pattern };
    if (true) unreachable;
    _ = try opts.transformation.inverse();
    if (nodes.len == 0) return;
    const minimum_line_width: f64 = 0.00390625;
    var polygons = try stroke_plotter.plot(
        alloc,
        nodes,
        .{
            .cap_mode = if (opts.line_width >= 2) opts.line_cap_mode else .butt,
            .ctm = opts.transformation,
            .dashes = opts.dashes,
            .dash_offset = opts.dash_offset,
            .join_mode = if (opts.line_width >= 2) opts.line_join_mode else .miter,
            .miter_limit = if (opts.line_width >= 2) opts.miter_limit else 10.0,
            .scale = 1,
            .thickness = if (opts.line_width >= minimum_line_width)
                opts.line_width
            else
                minimum_line_width,
            .tolerance = @max(opts.tolerance, 0.001),
        },
    );
    defer polygons.deinit(alloc);
}

pub const WebGPURenderer = struct {
    pub const Vertex1 = struct {
        pos: [2]f32,
        col: [4]u8,
        pub fn append_to_list(Self: @This(), list: anytype) !void {
            try list.appendSlice(std.mem.sliceAsBytes(&Self.pos));
            try list.appendSlice(std.mem.sliceAsBytes(&Self.col));
        }
        const attributes: []const wgpu.VertexAttribute =
            &.{
                .{
                    .format = wgpu.VertexFormat.float32x2,
                    .offset = 0,
                    .shader_location = 0,
                },
                .{
                    .format = wgpu.VertexFormat.unorm8x4,
                    .offset = 8,
                    .shader_location = 1,
                },
            };
        const layout: wgpu.VertexBufferLayout =
            .{
                .array_stride = 12,
                .step_mode = wgpu.VertexStepMode.vertex,
                .attributes = attributes.ptr,
                .attribute_count = attributes.len,
            };
    };
    const swap_chain_format = wgpu.TextureFormat.bgra8_unorm_srgb;
    instance: *wgpu.Instance,
    adapter: *wgpu.Adapter,
    device: *wgpu.Device,
    queue: *wgpu.Queue,
    pipeline: *wgpu.RenderPipeline,
    shader_module: *wgpu.ShaderModule,
    pub fn deinit(self: *@This()) void {
        defer self.instance.release();
        defer self.adapter.release();
        defer self.device.release();
        defer self.queue.release();
        defer self.shader_module.release();
        defer self.pipeline.release();
    }
    pub fn init(self: *@This()) !void {
        self.instance = wgpu.Instance.create(null).?;
        errdefer self.instance.release();
        self.adapter = self.instance.requestAdapterSync(&wgpu.RequestAdapterOptions{}, 0).adapter orelse return error.NoAdapter;
        errdefer self.adapter.release();
        self.device = self.adapter.requestDeviceSync(self.instance, &wgpu.DeviceDescriptor{
            .required_limits = null,
        }, 0).device orelse return error.NoDevice;
        errdefer self.device.release();
        self.queue = self.device.getQueue().?;
        errdefer self.queue.release();
        try self.init_shader_module();
        errdefer self.shader_module.release();
        try self.init_pipeline();
        errdefer self.pipeline.release();
    }
    fn init_shader_module(self: *@This()) !void {
        const shader_code = @embedFile("shader.wgsl");
        self.shader_module = self.device.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(.{
            .code = shader_code,
        })).?;
    }
    fn init_pipeline(self: *@This()) !void {
        const color_targets = &[_]wgpu.ColorTargetState{
            wgpu.ColorTargetState{
                .format = swap_chain_format,
                .blend = &wgpu.BlendState{
                    .color = wgpu.BlendComponent{
                        .operation = .add,
                        .src_factor = .src_alpha,
                        .dst_factor = .one_minus_src_alpha,
                    },
                    .alpha = wgpu.BlendComponent{
                        .operation = .add,
                        .src_factor = .zero,
                        .dst_factor = .one,
                    },
                },
            },
        };
        self.pipeline = self.device.createRenderPipeline(&wgpu.RenderPipelineDescriptor{
            .vertex = wgpu.VertexState{
                .module = self.shader_module,
                .entry_point = wgpu.StringView.fromSlice("vertex_shader"),
                .buffers = &.{Vertex1.layout},
                .buffer_count = 1,
            },
            .fragment = &wgpu.FragmentState{ .module = self.shader_module, .entry_point = wgpu.StringView.fromSlice("fragment_shader"), .target_count = color_targets.len, .targets = color_targets.ptr },
            .primitive = wgpu.PrimitiveState{
                .topology = wgpu.PrimitiveTopology.triangle_strip,
                .front_face = wgpu.FrontFace.ccw,
                .cull_mode = wgpu.CullMode.none,
            },
            .multisample = wgpu.MultisampleState{},
        }) orelse return error.CreateRenderPipeline;
    }
};

const stroke_plotter = struct {
    pub fn plot() !void {}
};
const PointF32 = extern struct {
    x: f32,
    y: f32,
    pub fn cast(self: @This()) Point {
        return Point{
            .x = @floatCast(self.x),
            .y = @floatCast(self.y),
        };
    }
    // Add an `equal` method for PointF32 if needed for `line_to` logic,
    // or cast to Point for comparison.
    pub fn equal(self: @This(), other: PointF32) bool {
        return self.x == other.x and self.y == other.y;
    }
};

pub const CountourList = struct {
    const Range = struct {
        start: usize, // Start index of this contour in the `points` array
        end: usize, // End index (exclusive) of this contour in the `points` array
    };
    points: std.ArrayList(PointF32),
    range: std.ArrayList(Range),
    current_contour_start_idx: usize = 0, // Renamed 'start' for clarity

    pub fn init(alloc: std.mem.Allocator) CountourList {
        return .{
            .points = std.ArrayList(PointF32).init(alloc),
            .range = std.ArrayList(Range).init(alloc),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.range.deinit();
        self.points.deinit();
    }

    pub fn append_point(self: *@This(), p: Point) !void {
        try self.points.append(PointF32{ .x = @floatCast(p.x), .y = @floatCast(p.y) });
    }

    /// Finalizes the current contour and prepares for a new one.
    /// This should be called before starting a new sub-path (move_to)
    /// or after closing a path (close_path).
    pub fn finalize_current_contour(self: *@This()) !void {
        const current_end_idx = self.points.items.len;
        if (self.current_contour_len() > 0) {
            try self.range.append(.{
                .start = self.current_contour_start_idx,
                .end = current_end_idx,
            });
        }
        self.current_contour_start_idx = current_end_idx;
    }

    /// Gets the last point of the current contour.
    pub fn last_current_point(self: *@This()) ?Point {
        if (self.current_contour_len() == 0) return null;
        return self.points.items[self.points.items.len - 1].cast();
    }

    /// Gets the first point of the current contour.
    pub fn first_current_point(self: *@This()) ?Point {
        if (self.current_contour_len() == 0) return null;
        return self.points.items[self.current_contour_start_idx].cast();
    }

    /// Returns the number of points in the current (unfinalized) contour.
    pub fn current_contour_len(self: *@This()) usize {
        return self.points.items.len - self.current_contour_start_idx;
    }
};
const fill_plotter = struct {
    const Spline = @import("internal/Spline.zig");
    const PlotterVTable = @import("internal/PlotterVTable.zig");

    pub const Error = InternalError || mem.Allocator.Error;

    pub fn plot(
        alloc: mem.Allocator,
        nodes: []const Path.PathNode,
        tolerance: f64, // Add tolerance for curve decomposition
    ) !CountourList {
        var contours = CountourList.init(alloc);
        var current_path_start_point: ?Point = null;
        for (nodes, 0..) |node, i| {
            switch (node) {
                .move_to => |n| {
                    if (i == nodes.len - 1) break;
                    // Finalize the previous contour (if any) before starting a new one
                    try contours.finalize_current_contour();
                    // Start new contour with the move_to point
                    try contours.append_point(n.point);
                    current_path_start_point = n.point; // Store for close_path
                },
                .line_to => |n| {
                    const last_point = contours.last_current_point() orelse return error.InvalidState;
                    if (!last_point.equal(n.point)) { // Avoid duplicate points
                        try contours.append_point(n.point);
                    }
                },
                .curve_to => |n| {
                    const last_point = contours.last_current_point() orelse return error.InvalidState;
                    if (last_point.equal(n.p3)) continue;

                    var spline_ctx: SplinePlotterCtx = .{
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
                            .line_to = SplinePlotterCtx.line_to_add_to_contour,
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

    const SplinePlotterCtx = struct {
        contour_list: *CountourList, // Now a pointer to the CountourList
        alloc: mem.Allocator,
        fn line_to_add_to_contour(ctx: *anyopaque, err_: *?PlotterVTable.Error, node: nodepkg.PathLineTo) void {
            const self: *SplinePlotterCtx = @ptrCast(@alignCast(ctx));
            // Spline.decompose() should call this for each segment it generates.
            // We add the point to the current contour.
            // Avoid adding duplicate points if the tessellation algorithm generates them.
            if (self.contour_list.last_current_point()) |last_p| {
                if (last_p.equal(node.point)) {
                    return; // Point is same as last one, skip
                }
            }
            self.contour_list.append_point(node.point) catch |err| {
                err_.* = err; // Propagate allocation error
                return;
            };
        }
    };
};
