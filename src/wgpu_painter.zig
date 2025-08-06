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
const og_painter = @import("painter.zig");
const FillOpts = og_painter.FillOpts;
const StrokeOpts = og_painter.StrokeOpts;
const Spline = @import("internal/Spline.zig");
const PlotterVTable = @import("internal/PlotterVTable.zig");
const InternalError = @import("internal/InternalError.zig").InternalError;
const WgpuPolygon = @import("internal/wgpu_Polygon.zig");
const Range = WgpuPolygon.Range;
const PointF32 = WgpuPolygon.PointF32;
const fill_plotter = @import("internal/wgpu_fill_plotter.zig");
const stroke_plotter = @import("internal/wgpu_stroke_plotter.zig");

const debug_logging = false;

pub const Painter = struct {
    alloc: mem.Allocator,
    arena: std.heap.ArenaAllocator,
    batch_vertices: BatchVertices,
    batch_indexes: BatchTriangles,
    gpu_renderer: WgpuRender,
    pub fn init(alloc: mem.Allocator, aa_mode: options.AntiAliasMode) !@This() {
        var ren: WgpuRender = undefined;
        try ren.init(aa_mode);
        return @This(){
            .alloc = alloc,
            .arena = .init(alloc),
            .batch_vertices = .init(alloc),
            .batch_indexes = .init(alloc),
            .gpu_renderer = ren,
        };
    }
    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        self.batch_vertices.deinit();
        self.batch_indexes.deinit();
    }
    pub fn finalize(self: *@This(), sfc: *Surface) !void {
        switch (self.gpu_renderer.aa_mode) {
            .default => try self.gpu_renderer.render_triangle_list(sfc, &self.batch_vertices, &self.batch_indexes, true),
            .none => try self.gpu_renderer.render_triangle_list(sfc, &self.batch_vertices, &self.batch_indexes, false),
        }
    }
    pub fn add_tesselated_triangles_to_batch(self: *@This(), tess: *libtess.TESStesselator, pattern: *const Pattern) !void {
        const offset = std.math.cast(i32, (self.batch_vertices.total_len())) orelse return InternalError.InvalidState;
        const triangle_count = libtess.tessGetElementCount(tess);
        const vertices_pointer: [*]const PointF32 = @ptrCast(libtess.tessGetVertices(tess));
        var vertices: []const PointF32 = undefined;
        vertices.ptr = vertices_pointer;
        vertices.len = @intCast(libtess.tessGetVertexCount(tess));
        for (vertices) |v| {
            const color = pattern.getPixel(@intFromFloat(v.x), @intFromFloat(v.y));
            const color_arr = mem.bytesToValue([4]u8, mem.asBytes(&color.rgba));
            try self.batch_vertices.add_vertex(v, color_arr);
        }
        try self.batch_vertices.finalize_vertex_list();
        var index_slices: []const c_int = undefined;
        index_slices.ptr = libtess.tessGetElements(tess);
        index_slices.len = @intCast(triangle_count * 3);
        for (index_slices) |idx| {
            try self.batch_indexes.add_index(@intCast(idx));
        }
        try self.batch_indexes.finalize_index_list(offset);
    }

    pub fn fill(
        self: *Painter,
        pattern: *const Pattern,
        nodes: []const PathNode,
        opts: FillOpts,
    ) !void {
        if (nodes.len == 0) return;
        if (!PathNode.isClosedNodeSet(nodes)) return error.PathNotClosed;
        var alloc = self.arena.allocator();
        defer _ = self.arena.reset(.retain_capacity);
        var polygons = try fill_plotter.plot(alloc, nodes, @max(opts.tolerance, 0.001));
        defer polygons.deinit();
        var tess_alloc = libtess_util.tess_alloc_from(&alloc);
        const tess = libtess.tessNewTess(&tess_alloc) orelse return InternalError.InvalidState;
        defer libtess.tessDeleteTess(tess);
        const points = polygons.points.items;
        for (polygons.range.items) |range| {
            const slice = points[range.start..range.end];
            const ptr: *anyopaque = @alignCast(@ptrCast(slice.ptr));
            libtess.tessAddContour(tess, 2, ptr, @sizeOf(PointF32), @intCast(slice.len));
        }
        const tess_winding = switch (opts.fill_rule) {
            .even_odd => libtess.TESS_WINDING_ODD,
            .non_zero => libtess.TESS_WINDING_NONZERO,
        };
        const res = libtess.tessTesselate(tess, tess_winding, libtess.TESS_POLYGONS, 3, 2, null);
        if (res != 1) return error.TesselateFailed;
        try self.add_tesselated_triangles_to_batch(tess, pattern);
    }

    pub fn stroke(
        self: *Painter,
        pattern: *const Pattern,
        nodes: []const PathNode,
        opts: StrokeOpts,
    ) !void {
        _ = try opts.transformation.inverse();
        if (nodes.len == 0) return;
        const minimum_line_width: f64 = 0.00390625;
        var alloc = self.arena.allocator();
        defer _ = self.arena.reset(.retain_capacity);
        const cap_mode: options.CapMode = if (opts.line_width >= 2) opts.line_cap_mode else .butt;
        const ctm: Transformation = opts.transformation;
        const dashes: []const f64 = opts.dashes;
        const dash_offset: f64 = opts.dash_offset;
        const join_mode: options.JoinMode = if (opts.line_width >= 2) opts.line_join_mode else .miter;
        const miter_limit: f64 = if (opts.line_width >= 2) opts.miter_limit else 10.0;
        const thickness: f64 = if (opts.line_width >= minimum_line_width) opts.line_width else minimum_line_width;
        const tolerance: f64 = @max(opts.tolerance, 0.001);

        var polygons = try stroke_plotter.plot(alloc, nodes, .{
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
        defer polygons.deinit();

        var tess_alloc = libtess_util.tess_alloc_from(&alloc);
        const tess = libtess.tessNewTess(&tess_alloc) orelse return InternalError.InvalidState;
        defer libtess.tessDeleteTess(tess);

        const points = polygons.points.items;
        for (polygons.range.items) |range| {
            const slice = points[range.start..range.end];
            const ptr: *anyopaque = @alignCast(@ptrCast(slice.ptr));
            libtess.tessAddContour(tess, 2, ptr, @sizeOf(PointF32), @intCast(slice.len));
        }
        const tess_winding = libtess.TESS_WINDING_NONZERO;
        const res = libtess.tessTesselate(tess, tess_winding, libtess.TESS_POLYGONS, 3, 2, null);
        if (res != 1) return error.TesselateFailed;
        try self.add_tesselated_triangles_to_batch(tess, pattern);

        log_path_nodes(nodes);
        log_polygon(polygons);
    }
};
fn log_polygon(
    polygon: WgpuPolygon,
) void {
    for (polygon.range.items, 0..) |r, i| {
        const contour = polygon.points.items[r.start..r.end];
        debug_log("contour {}:", .{i});
        for (contour) |p| {
            debug_log("p {d:.3},{d:.3}", .{ p.x, p.y });
        }
    }
}
fn log_path_nodes(
    nodes: []const PathNode,
) void {
    for (nodes) |n| {
        debug_log("node {any}", .{n});
    }
}

const BatchTriangles = struct {
    indices: std.ArrayList(u32), // flat list of index lists without offset
    range: std.ArrayList(Range), // range indexes into indices,
    range_index_offset: std.ArrayList(i32), // the offset for a index list
    range_start_idx: usize = 0,
    pub fn init(gpa: std.mem.Allocator) BatchTriangles {
        return .{
            .indices = std.ArrayList(u32).init(gpa),
            .range = std.ArrayList(Range).init(gpa),
            .range_index_offset = std.ArrayList(i32).init(gpa),
        };
    }
    pub fn deinit(self: *@This()) void {
        self.range_index_offset.deinit();
        self.range.deinit();
        self.indices.deinit();
    }
    pub fn add_index(self: *@This(), index: u32) !void {
        try self.indices.append(index);
    }
    pub fn finalize_index_list(self: *@This(), vertex_index_offset: i32) !void {
        const current_end_idx = self.indices.items.len;
        if (self.current_len() > 0) {
            try self.range.append(.{
                .start = self.range_start_idx,
                .end = current_end_idx,
            });
            errdefer _ = self.range.pop();
            try self.range_index_offset.append(vertex_index_offset);
        }
        self.range_start_idx = current_end_idx;
    }
    pub fn get_triangle_list(self: *const @This(), idx: usize) struct {
        triangle_index_offset: usize,
        vertex_index_offset: i32,
        index_list: []const u32,
    } {
        const range = self.range.items[idx];
        return .{
            .triangle_index_offset = range.start,
            .vertex_index_offset = self.range_index_offset.items[idx],
            .index_list = self.indices.items[range.start..range.end],
        };
    }
    pub fn lookup_point(_: *const @This(), vertices: *const BatchVertices, index: u32, vertex_offset: i32) struct { p: PointF32, c: Color4U8 } {
        const global_index = @as(usize, index) + @as(usize, @intCast(vertex_offset));
        const c = vertices.vertex_colors.items[global_index];
        const p = vertices.vertex_points.items[global_index];
        return .{
            .p = p,
            .c = c,
        };
    }
    pub fn number_of_triangle_lists(self: *const @This()) usize {
        return self.range.items.len;
    }
    pub fn max_len_index_list(self: *const @This()) usize {
        var max: usize = 0;
        for (0..self.number_of_triangle_lists()) |i| {
            const l = self.get_triangle_list(i).index_list.len;
            if (l > max) max = l;
        }
        return max;
    }
    pub fn current_len(self: *const @This()) usize {
        return self.indices.items.len - self.range_start_idx;
    }
};

const Color4U8 = [4]u8;
const BatchVertices = struct {
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
    pub fn add_vertex(self: *@This(), point: PointF32, color: [4]u8) !void {
        try self.vertex_points.append(point);
        try self.vertex_colors.append(color);
    }
    pub fn finalize_vertex_list(self: *@This()) !void {
        const current_end_idx = self.vertex_points.items.len;
        if (self.current_len() > 0) {
            try self.range.append(.{
                .start = self.range_start_idx,
                .end = current_end_idx,
            });
        }
        self.range_start_idx = current_end_idx;
    }
    pub fn current_len(self: *const @This()) usize {
        return self.vertex_colors.items.len - self.range_start_idx;
    }
    pub fn total_len(self: *const @This()) usize {
        return self.vertex_colors.items.len;
    }
};

pub const WgpuRender = struct {
    pub const VertexPosition = struct {
        const attributes: []const wgpu.VertexAttribute =
            &.{
                .{
                    .format = wgpu.VertexFormat.float32x2,
                    .offset = 0,
                    .shader_location = 0,
                },
            };
        const layout: wgpu.VertexBufferLayout =
            .{
                .array_stride = @sizeOf([2]f32),
                .step_mode = wgpu.VertexStepMode.vertex,
                .attributes = attributes.ptr,
                .attribute_count = attributes.len,
            };
    };

    pub const VertexColor = struct {
        const attributes: []const wgpu.VertexAttribute =
            &.{
                .{
                    .format = wgpu.VertexFormat.unorm8x4,
                    .offset = 0,
                    .shader_location = 1,
                },
            };
        const layout: wgpu.VertexBufferLayout =
            .{
                .array_stride = @sizeOf([4]u8),
                .step_mode = wgpu.VertexStepMode.vertex,
                .attributes = attributes.ptr,
                .attribute_count = attributes.len,
            };
    };

    const swap_chain_format = wgpu.TextureFormat.rgba8_unorm;

    instance: *wgpu.Instance,
    adapter: *wgpu.Adapter,
    device: *wgpu.Device,
    queue: *wgpu.Queue,
    pipeline: *wgpu.RenderPipeline,
    shader_module: *wgpu.ShaderModule,

    bind_group_layout: *wgpu.BindGroupLayout,
    screen_size_buffer: *wgpu.Buffer,

    // Store the anti-aliasing mode
    aa_mode: options.AntiAliasMode,

    pub fn deinit(self: *@This()) void {
        defer self.instance.release();
        defer self.adapter.release();
        defer self.device.release();
        defer self.queue.release();
        defer self.shader_module.release();
        defer self.pipeline.release();
        defer self.bind_group_layout.release();
        defer self.screen_size_buffer.release();
    }

    pub fn init(self: *@This(), aamode: options.AntiAliasMode) !void {
        self.aa_mode = aamode;
        self.instance = wgpu.Instance.create(null) orelse return error.NoInstance;
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

        // Initialize new uniform buffer objects
        try self.init_bind_group_layout();
        errdefer self.bind_group_layout.release();
        self.screen_size_buffer = self.device.createBuffer(&wgpu.BufferDescriptor{
            .label = wgpu.StringView.fromSlice("Screen Size Uniform Buffer"),
            .size = @sizeOf([2]f32),
            .usage = wgpu.BufferUsages.uniform | wgpu.BufferUsages.copy_dst,
            .mapped_at_creation = @as(u32, @intFromBool(false)),
        }).?;
        errdefer self.screen_size_buffer.release();

        try self.init_pipeline();
        errdefer self.pipeline.release();
    }

    fn init_shader_module(self: *@This()) !void {
        const shader_code = @embedFile("wgpu_shader.wgsl");
        self.shader_module = self.device.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(.{
            .code = shader_code,
        })).?;
    }

    fn init_bind_group_layout(self: *@This()) !void {
        const bind_group_layout_entries = &[_]wgpu.BindGroupLayoutEntry{
            wgpu.BindGroupLayoutEntry{
                .binding = 0,
                .visibility = wgpu.ShaderStages.vertex,
                .buffer = wgpu.BufferBindingLayout{
                    .type = wgpu.BufferBindingType.uniform,
                    .min_binding_size = @sizeOf([2]f32),
                },
            },
        };
        self.bind_group_layout = self.device.createBindGroupLayout(&wgpu.BindGroupLayoutDescriptor{
            .label = wgpu.StringView.fromSlice("Screen Size Bind Group Layout"),
            .entry_count = bind_group_layout_entries.len,
            .entries = bind_group_layout_entries.ptr,
        }).?;
    }

    fn init_pipeline(self: *@This()) !void {
        const color_targets = &[_]wgpu.ColorTargetState{
            wgpu.ColorTargetState{
                .format = swap_chain_format,
                .blend = &wgpu.BlendState{
                    .color = wgpu.BlendComponent{
                        .operation = .add,
                        .src_factor = .one, // premultiplied
                        .dst_factor = .one_minus_src_alpha,
                    },
                    .alpha = wgpu.BlendComponent{
                        .operation = .add,
                        .src_factor = .one,
                        .dst_factor = .one_minus_src_alpha,
                    },
                },
            },
        };
        const buffers: []const wgpu.VertexBufferLayout = &.{
            VertexPosition.layout,
            VertexColor.layout,
        };

        // Create a pipeline layout that includes our bind group layout
        const bind_group_layouts: []const *wgpu.BindGroupLayout = &.{self.bind_group_layout};
        const pipeline_layout = self.device.createPipelineLayout(&wgpu.PipelineLayoutDescriptor{
            .label = wgpu.StringView.fromSlice("Render Pipeline Layout"),
            .bind_group_layout_count = bind_group_layouts.len,
            .bind_group_layouts = bind_group_layouts.ptr,
        }).?;
        defer pipeline_layout.release();

        var pipeline_desc = wgpu.RenderPipelineDescriptor{
            .layout = pipeline_layout,
            .vertex = wgpu.VertexState{
                .module = self.shader_module,
                .entry_point = wgpu.StringView.fromSlice("vertex_shader2"),
                .buffers = buffers.ptr,
                .buffer_count = buffers.len,
            },
            .fragment = &wgpu.FragmentState{ .module = self.shader_module, .entry_point = wgpu.StringView.fromSlice("fragment_shader2"), .target_count = color_targets.len, .targets = color_targets.ptr },
            .primitive = wgpu.PrimitiveState{
                .topology = wgpu.PrimitiveTopology.triangle_list,
                .front_face = wgpu.FrontFace.ccw,
                .cull_mode = wgpu.CullMode.none,
            },
            .multisample = .{},
        };
        if (self.aa_mode == .default) {
            pipeline_desc.multisample = wgpu.MultisampleState{
                .count = 4,
                .mask = 0xFFFFFFFF,
                .alpha_to_coverage_enabled = @as(u32, @intFromBool(false)),
            };
        }
        self.pipeline = self.device.createRenderPipeline(&pipeline_desc) orelse return error.CreateRenderPipeline;
    }

    const WgpuError = error{
        createBuffer,
        createTexture,
        createView,
        createBindgroup,
        createCommandEncoder,
        beginRenderPass,
        encoderFinish,
    };

    pub fn render_triangle_list(self: *WgpuRender, sfc: *Surface, triangle_vertices: *const BatchVertices, triangles: *const BatchTriangles, anti_aliased: bool) !void {
        const positions = triangle_vertices.vertex_points.items;
        const colors = triangle_vertices.vertex_colors.items;
        const position_data_bytes = std.mem.sliceAsBytes(positions);
        const color_data_bytes = std.mem.sliceAsBytes(colors);

        const position_buffer = self.device.createBuffer(&wgpu.BufferDescriptor{
            .label = wgpu.StringView.fromSlice("Position Buffer"),
            .size = position_data_bytes.len,
            .usage = wgpu.BufferUsages.vertex | wgpu.BufferUsages.copy_dst,
            .mapped_at_creation = @as(u32, @intFromBool(false)),
        }) orelse return WgpuError.createBuffer;
        defer position_buffer.release();

        const color_buffer = self.device.createBuffer(&wgpu.BufferDescriptor{
            .label = wgpu.StringView.fromSlice("Color Buffer"),
            .size = color_data_bytes.len,
            .usage = wgpu.BufferUsages.vertex | wgpu.BufferUsages.copy_dst,
            .mapped_at_creation = @as(u32, @intFromBool(false)),
        }) orelse return WgpuError.createBuffer;
        defer color_buffer.release();

        const total_index_data_len = triangles.indices.items.len * @sizeOf(u32);
        const index_buffer = self.device.createBuffer(&wgpu.BufferDescriptor{
            .label = wgpu.StringView.fromSlice("Index Buffer"),
            .size = total_index_data_len,
            .usage = wgpu.BufferUsages.index | wgpu.BufferUsages.copy_dst,
            .mapped_at_creation = @as(u32, @intFromBool(false)),
        }) orelse return WgpuError.createBuffer;
        defer index_buffer.release();

        self.queue.writeBuffer(position_buffer, 0, position_data_bytes.ptr, position_data_bytes.len);
        self.queue.writeBuffer(color_buffer, 0, color_data_bytes.ptr, color_data_bytes.len);
        self.queue.writeBuffer(index_buffer, 0, std.mem.sliceAsBytes(triangles.indices.items).ptr, total_index_data_len);

        const output_extent = wgpu.Extent3D{
            .width = @intCast(sfc.getWidth()),
            .height = @intCast(sfc.getHeight()),
            .depth_or_array_layers = 1,
        };
        const alignment: u32 = 256;
        const unaligned_bytes_per_row = 4 * output_extent.width;
        const output_bytes_per_row = (unaligned_bytes_per_row + alignment - 1) & ~(alignment - 1);
        const output_size = output_bytes_per_row * output_extent.height;

        var render_texture: *wgpu.Texture = undefined;
        var render_texture_view: *wgpu.TextureView = undefined;
        var resolve_texture: *wgpu.Texture = undefined;
        var resolve_texture_view: *wgpu.TextureView = undefined;
        var texture_to_copy_from: *wgpu.Texture = undefined;
        var store_op: wgpu.StoreOp = undefined;

        if (anti_aliased) {
            render_texture = self.device.createTexture(&wgpu.TextureDescriptor{
                .label = wgpu.StringView.fromSlice("MSAA render texture"),
                .size = output_extent,
                .format = swap_chain_format,
                .usage = wgpu.TextureUsages.render_attachment,
                .sample_count = 4,
            }) orelse return WgpuError.createTexture;
            errdefer render_texture.release();

            render_texture_view = render_texture.createView(&wgpu.TextureViewDescriptor{
                .label = wgpu.StringView.fromSlice("MSAA render texture view"),
                .mip_level_count = 1,
                .array_layer_count = 1,
            }) orelse return WgpuError.createView;
            errdefer render_texture_view.release();

            resolve_texture = self.device.createTexture(&wgpu.TextureDescriptor{
                .label = wgpu.StringView.fromSlice("Render resolve texture"),
                .size = output_extent,
                .format = swap_chain_format,
                .usage = wgpu.TextureUsages.render_attachment | wgpu.TextureUsages.copy_src,
                .sample_count = 1,
            }) orelse return WgpuError.createTexture;
            errdefer resolve_texture.release();

            resolve_texture_view = resolve_texture.createView(&wgpu.TextureViewDescriptor{
                .label = wgpu.StringView.fromSlice("Render resolve texture view"),
                .mip_level_count = 1,
                .array_layer_count = 1,
            }) orelse return WgpuError.createView;
            errdefer resolve_texture_view.?.release();

            texture_to_copy_from = resolve_texture;
            store_op = wgpu.StoreOp.discard;
        } else {
            render_texture = self.device.createTexture(&wgpu.TextureDescriptor{
                .label = wgpu.StringView.fromSlice("Render texture (no MSAA)"),
                .size = output_extent,
                .format = swap_chain_format,
                .usage = wgpu.TextureUsages.render_attachment | wgpu.TextureUsages.copy_src,
                .sample_count = 1,
            }) orelse return WgpuError.createTexture;
            errdefer render_texture.release();

            render_texture_view = render_texture.createView(&wgpu.TextureViewDescriptor{
                .label = wgpu.StringView.fromSlice("Render texture view (no MSAA)"),
                .mip_level_count = 1,
                .array_layer_count = 1,
            }) orelse return WgpuError.createView;
            errdefer render_texture_view.release();
            resolve_texture_view = undefined;
            texture_to_copy_from = render_texture;
            store_op = wgpu.StoreOp.store;
        }
        defer if (anti_aliased) {
            resolve_texture_view.release();
            resolve_texture.release();
            render_texture_view.release();
            render_texture.release();
        } else {
            render_texture_view.release();
            render_texture.release();
        };

        const gpu_output_buffer = self.device.createBuffer(&wgpu.BufferDescriptor{
            .label = wgpu.StringView.fromSlice("staging_buffer"),
            .usage = wgpu.BufferUsages.map_read | wgpu.BufferUsages.copy_dst,
            .size = output_size,
            .mapped_at_creation = @as(u32, @intFromBool(false)),
        }) orelse return WgpuError.createBuffer;
        defer gpu_output_buffer.release();

        const screen_size = [2]f32{ @as(f32, @floatFromInt(sfc.getWidth())), @as(f32, @floatFromInt(sfc.getHeight())) };
        const screen_size_bytes = std.mem.sliceAsBytes(&screen_size);
        self.queue.writeBuffer(self.screen_size_buffer, 0, screen_size_bytes.ptr, screen_size_bytes.len);

        const bindgroup_entries: []const wgpu.BindGroupEntry = &.{
            wgpu.BindGroupEntry{
                .binding = 0,
                .buffer = self.screen_size_buffer,
                .offset = 0,
                .size = @sizeOf([2]f32),
            },
        };
        const bind_group = self.device.createBindGroup(&wgpu.BindGroupDescriptor{
            .label = wgpu.StringView.fromSlice("Screen Size Bind Group"),
            .layout = self.bind_group_layout,
            .entry_count = bindgroup_entries.len,
            .entries = bindgroup_entries.ptr,
        }) orelse return WgpuError.createBindgroup;
        defer bind_group.release();

        const encoder = self.device.createCommandEncoder(&wgpu.CommandEncoderDescriptor{
            .label = wgpu.StringView.fromSlice("Command Encoder"),
        }) orelse return WgpuError.createCommandEncoder;
        defer encoder.release();

        const color_attachments = &[_]wgpu.ColorAttachment{wgpu.ColorAttachment{
            .view = render_texture_view,
            .resolve_target = resolve_texture_view,
            .clear_value = wgpu.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .load_op = wgpu.LoadOp.clear,
            .store_op = store_op,
        }};
        const render_pass = encoder.beginRenderPass(&wgpu.RenderPassDescriptor{
            .color_attachment_count = color_attachments.len,
            .color_attachments = color_attachments.ptr,
        }) orelse return WgpuError.beginRenderPass;
        defer render_pass.release();

        render_pass.setPipeline(self.pipeline);
        render_pass.setBindGroup(0, bind_group, 0, null);
        render_pass.setVertexBuffer(0, position_buffer, 0, position_data_bytes.len);
        render_pass.setVertexBuffer(1, color_buffer, 0, color_data_bytes.len);
        debug_log("Begin Rendering process", .{});

        render_pass.setIndexBuffer(index_buffer, wgpu.IndexFormat.uint32, 0, total_index_data_len);

        for (0..triangles.number_of_triangle_lists()) |i| {
            const t = triangles.get_triangle_list(i);
            debug_log("render triangle list {d} with drawIndexed (index_count={d}, vertex_idx_offset={d}, indices_idx_offset={d})", .{ i, t.index_list.len, t.vertex_index_offset, t.triangle_index_offset });
            for (t.index_list) |idx| {
                const v = triangles.lookup_point(triangle_vertices, idx, t.vertex_index_offset);
                debug_log("vertex: {d:.3}, {d:.3}", .{ v.p.x, v.p.y });
            }
            render_pass.drawIndexed(
                @intCast(t.index_list.len),
                1,
                @intCast(t.triangle_index_offset),
                t.vertex_index_offset,
                0,
            );
        }

        render_pass.end();

        const img_copy_src = wgpu.TexelCopyTextureInfo{
            .origin = wgpu.Origin3D{},
            .texture = texture_to_copy_from,
        };
        const img_copy_dst = wgpu.TexelCopyBufferInfo{
            .layout = wgpu.TexelCopyBufferLayout{
                .bytes_per_row = output_bytes_per_row,
                .rows_per_image = output_extent.height,
            },
            .buffer = gpu_output_buffer,
        };

        encoder.copyTextureToBuffer(&img_copy_src, &img_copy_dst, &output_extent);

        const command_buffer = encoder.finish(&wgpu.CommandBufferDescriptor{
            .label = wgpu.StringView.fromSlice("Command Buffer"),
        }) orelse return WgpuError.encoderFinish;
        defer command_buffer.release();

        self.queue.submit(&[_]*const wgpu.CommandBuffer{command_buffer});

        var buffer_map_complete = false;
        _ = gpu_output_buffer.mapAsync(wgpu.MapModes.read, 0, output_size, wgpu.BufferMapCallbackInfo{
            .callback = handleBufferMap,
            .userdata1 = @ptrCast(&buffer_map_complete),
        });
        self.instance.processEvents();
        while (!buffer_map_complete) {
            self.instance.processEvents();
        }

        const buf: [*]u8 = @ptrCast(@alignCast(gpu_output_buffer.getMappedRange(0, output_size).?));
        defer gpu_output_buffer.unmap();
        const raw_output_bytes: []const u8 = buf[0..output_size];

        const view_width: usize = @intCast(output_extent.width);
        const view_height: usize = @intCast(output_extent.height);
        const output_pixel_stride: usize = output_bytes_per_row / @sizeOf(pixel.RGBA);

        for (0..view_height) |h| {
            const row_start_byte_offset = h * output_pixel_stride * @sizeOf(pixel.RGBA);
            const row_end_byte_offset = row_start_byte_offset + (view_width * @sizeOf(pixel.RGBA));
            const row_bytes = raw_output_bytes[row_start_byte_offset..row_end_byte_offset];
            const row_pixels: []const z2d.pixel.RGBA = @alignCast(std.mem.bytesAsSlice(z2d.pixel.RGBA, row_bytes));
            for (0..view_width) |w| {
                const px = z2d.Pixel{ .rgba = row_pixels[w] };
                const og_px = sfc.getPixel(@intCast(w), @intCast(h)).?;
                sfc.putPixel(@intCast(w), @intCast(h), compositor.runPixel(.float, px, og_px, .src_over));
            }
        }
    }
    fn handleBufferMap(status: wgpu.MapAsyncStatus, _: wgpu.StringView, userdata1: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {
        debug_log("buffer_map status={x:.8}\n", .{@intFromEnum(status)});
        const complete: *bool = @ptrCast(@alignCast(userdata1));
        complete.* = true;
    }
};

fn debug_log(comptime fmt: anytype, arg: anytype) void {
    if (debug_logging) {
        std.log.warn(fmt, arg);
    }
}

// SPDX-License-Identifier: MPL-2.0
//    Copyright © 2024-2025 Chris Marchesi, nat3
