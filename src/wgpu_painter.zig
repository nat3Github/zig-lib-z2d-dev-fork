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

pub const Painter = struct {
    alloc: mem.Allocator,
    arena: std.heap.ArenaAllocator,
    batch_vertices: BatchTriangleVertices,
    batch_indexes: BatchTriangleIndices,
    gpu_renderer: WgpuRender,
    pub fn init(alloc: mem.Allocator) !@This() {
        var ren: WgpuRender = undefined;
        try ren.init();
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
        try self.gpu_renderer.render_triangle_list(sfc, &self.batch_vertices, &self.batch_indexes);
    }
    pub fn add_tesselated_triangles_to_batch(self: *@This(), tess: *libtess.TESStesselator, pattern: *const Pattern) !void {
        const triangle_count = libtess.tessGetElementCount(tess);
        const vertices_pointer: [*]const PointF32 = @ptrCast(libtess.tessGetVertices(tess));
        var vertices: []const PointF32 = undefined;
        const idx_offset: u32 = @intCast(self.batch_vertices.current_len());
        vertices.ptr = vertices_pointer;
        vertices.len = @intCast(libtess.tessGetVertexCount(tess));
        for (vertices) |v| {
            const color = pattern.getPixel(@intFromFloat(v.x), @intFromFloat(v.y));
            const color_arr = mem.bytesToValue([4]u8, mem.asBytes(&color.rgba));
            try self.batch_vertices.append(v, color_arr);
        }
        try self.batch_vertices.finalize();
        var index_slices: []const c_int = undefined;
        index_slices.ptr = libtess.tessGetElements(tess);
        index_slices.len = @intCast(triangle_count * 3);
        for (index_slices) |idx| {
            const idx_u32: u32 = @intCast(idx);
            try self.batch_indexes.append(idx_u32 + idx_offset);
        }
        try self.batch_indexes.finalize();
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
        const polygons = try fill_plotter.plot(alloc, nodes, @max(opts.tolerance, 0.001));
        var tess_alloc = libtess_util.tess_alloc_from(&alloc);
        const tess = libtess.tessNewTess(&tess_alloc) orelse return InternalError.InvalidState;
        const points = polygons.points.items;
        for (polygons.range.items) |range| {
            const slice = points[range.start..range.end];
            const ptr: *anyopaque = @alignCast(@ptrCast(slice.ptr));
            libtess.tessAddContour(tess, 2, ptr, @sizeOf(PointF32), @intCast(points.len));
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

        const points = polygons.points.items;
        for (polygons.range.items) |range| {
            const slice = points[range.start..range.end];
            const ptr: *anyopaque = @alignCast(@ptrCast(slice.ptr));
            libtess.tessAddContour(tess, 2, ptr, @sizeOf(PointF32), @intCast(points.len));
        }
        const tess_winding = libtess.TESS_WINDING_NONZERO;
        const res = libtess.tessTesselate(tess, tess_winding, libtess.TESS_POLYGONS, 3, 2, null);
        if (res != 1) return error.TesselateFailed;
        try self.add_tesselated_triangles_to_batch(tess, pattern);
    }
};

const BatchTriangleIndices = struct {
    indices: std.ArrayList(u32),
    range: std.ArrayList(Range),
    range_start_idx: usize = 0,
    pub fn init(gpa: std.mem.Allocator) BatchTriangleIndices {
        return .{
            .indices = std.ArrayList(u32).init(gpa),
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
        const current_end_idx = self.indices.items.len;
        if (self.current_len() > 0) {
            try self.range.append(.{
                .start = self.range_start_idx,
                .end = current_end_idx,
            });
        }
        self.range_start_idx = current_end_idx;
    }
    pub fn get_triangle_indices(self: *const @This(), idx: usize) []const u32 {
        const range = self.range.items[idx];
        return self.indices.items[range.start..range.end];
    }
    pub fn len(self: *const @This()) usize {
        return self.range.items.len;
    }
    pub fn max_len_index_list(self: *const @This()) usize {
        var max: usize = 0;
        for (0..self.len()) |i| {
            const l = self.get_triangle_indices(i).len;
            if (l > max) max = l;
        }
        return max;
    }
    pub fn current_len(self: *const @This()) usize {
        return self.indices.items.len - self.range_start_idx;
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
    pub fn current_len(self: *const @This()) usize {
        return self.vertex_colors.items.len - self.range_start_idx;
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

    const swap_chain_format = wgpu.TextureFormat.rgba8_unorm_srgb;

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
        const shader_code = @embedFile("wgpu_shader.wgsl");
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
                        .src_factor = .src_alpha, // Use source alpha for color
                        .dst_factor = .one_minus_src_alpha,
                    },
                    .alpha = wgpu.BlendComponent{
                        .operation = .add,
                        .src_factor = .one, // Take the source alpha directly
                        .dst_factor = .one_minus_src_alpha, // Mix with destination alpha
                        // OR, if you just want source alpha to overwrite destination:
                        // .src_factor = .one,
                        // .dst_factor = .zero, // This would make final_alpha = source_alpha
                    },
                },
            },
        };
        const buffers: []const wgpu.VertexBufferLayout = &.{
            VertexPosition.layout,
            VertexColor.layout,
        };
        self.pipeline = self.device.createRenderPipeline(&wgpu.RenderPipelineDescriptor{
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
            .multisample = wgpu.MultisampleState{},
        }) orelse return error.CreateRenderPipeline;
    }

    pub fn render_triangle_list(self: *WgpuRender, sfc: *Surface, triangle_vert: *const BatchTriangleVertices, triangle_idx: *const BatchTriangleIndices) !void {
        const positions = triangle_vert.vertex_points.items;
        const colors = triangle_vert.vertex_colors.items;
        const position_data_bytes = std.mem.sliceAsBytes(positions);
        const color_data_bytes = std.mem.sliceAsBytes(colors);

        const position_buffer = self.device.createBuffer(&wgpu.BufferDescriptor{
            .label = wgpu.StringView.fromSlice("Position Buffer"),
            .size = position_data_bytes.len,
            .usage = wgpu.BufferUsages.vertex | wgpu.BufferUsages.copy_dst,
            .mapped_at_creation = @as(u32, @intFromBool(false)),
        }).?;
        defer position_buffer.release();

        const color_buffer = self.device.createBuffer(&wgpu.BufferDescriptor{
            .label = wgpu.StringView.fromSlice("Color Buffer"),
            .size = color_data_bytes.len,
            .usage = wgpu.BufferUsages.vertex | wgpu.BufferUsages.copy_dst,
            .mapped_at_creation = @as(u32, @intFromBool(false)),
        }).?;
        defer color_buffer.release();

        const max_index_data_len = triangle_idx.max_len_index_list() * @sizeOf(u32);
        const index_buffer = self.device.createBuffer(&wgpu.BufferDescriptor{
            .label = wgpu.StringView.fromSlice("Index Buffer"),
            .size = max_index_data_len, // allocate for the largest possible index list
            .usage = wgpu.BufferUsages.index | wgpu.BufferUsages.copy_dst,
            .mapped_at_creation = @as(u32, @intFromBool(false)),
        }).?;
        defer index_buffer.release();

        self.queue.writeBuffer(position_buffer, 0, position_data_bytes.ptr, position_data_bytes.len);
        self.queue.writeBuffer(color_buffer, 0, color_data_bytes.ptr, color_data_bytes.len);

        const output_extent = wgpu.Extent3D{
            .width = @intCast(sfc.getWidth()),
            .height = @intCast(sfc.getHeight()),
            .depth_or_array_layers = 1,
        };
        const alignment: u32 = 256;
        const unaligned_bytes_per_row = 4 * output_extent.width;
        const output_bytes_per_row = (unaligned_bytes_per_row + alignment - 1) & ~(alignment - 1);
        const output_size = output_bytes_per_row * output_extent.height;

        const target_texture = self.device.createTexture(&wgpu.TextureDescriptor{
            .label = wgpu.StringView.fromSlice("Render texture"),
            .size = output_extent,
            .format = swap_chain_format,
            .usage = wgpu.TextureUsages.render_attachment | wgpu.TextureUsages.copy_src,
        }).?;
        defer target_texture.release();

        const target_texture_view = target_texture.createView(&wgpu.TextureViewDescriptor{
            .label = wgpu.StringView.fromSlice("Render texture view"),
            .mip_level_count = 1,
            .array_layer_count = 1,
        }).?;
        defer target_texture_view.release();

        const gpu_output_buffer = self.device.createBuffer(&wgpu.BufferDescriptor{
            .label = wgpu.StringView.fromSlice("staging_buffer"),
            .usage = wgpu.BufferUsages.map_read | wgpu.BufferUsages.copy_dst,
            .size = output_size,
            .mapped_at_creation = @as(u32, @intFromBool(false)),
        }).?;
        defer gpu_output_buffer.release();

        // Begin command encoder and render pass once for all layers
        const encoder = self.device.createCommandEncoder(&wgpu.CommandEncoderDescriptor{
            .label = wgpu.StringView.fromSlice("Command Encoder"),
        }).?;
        defer encoder.release();

        const color_attachments = &[_]wgpu.ColorAttachment{wgpu.ColorAttachment{
            .view = target_texture_view,
            .clear_value = wgpu.Color{ .r = 1, .g = 0, .b = 1, .a = 0 },
            .load_op = wgpu.LoadOp.clear, // Clear the texture at the start of the pass
            .store_op = wgpu.StoreOp.store,
        }};
        const render_pass = encoder.beginRenderPass(&wgpu.RenderPassDescriptor{
            .color_attachment_count = color_attachments.len,
            .color_attachments = color_attachments.ptr,
        }).?;
        defer render_pass.release();

        render_pass.setPipeline(self.pipeline);
        // Set both vertex buffers once for the entire render pass
        render_pass.setVertexBuffer(0, position_buffer, 0, position_data_bytes.len); // Slot 0 for positions
        render_pass.setVertexBuffer(1, color_buffer, 0, color_data_bytes.len); // Slot 1 for colors

        for (0..triangle_idx.len()) |i| {
            const triangle_index_list = triangle_idx.get_triangle_indices(i);
            const index_data_bytes = std.mem.sliceAsBytes(triangle_index_list);

            // Update the index buffer for the current layer
            self.queue.writeBuffer(index_buffer, 0, index_data_bytes.ptr, index_data_bytes.len);

            // Set the index buffer and draw for the current layer
            render_pass.setIndexBuffer(index_buffer, wgpu.IndexFormat.uint32, 0, index_data_bytes.len);
            render_pass.drawIndexed(@intCast(triangle_index_list.len), 1, 0, 0, 0);

            std.log.warn("triangle list {}", .{i});
            for (triangle_index_list) |idx| {
                const p = positions[idx];
                std.log.warn("idx: {} vertex: {d:.3}, {d:.3}", .{ idx, p.x, p.y });
            }
        }

        render_pass.end(); // End the render pass after all layers are drawn

        const img_copy_src = wgpu.TexelCopyTextureInfo{
            .origin = wgpu.Origin3D{},
            .texture = target_texture,
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
        }).?;
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

        // --- START OF MODIFICATIONS FOR PIXEL COPY-BACK ---
        const buf: [*]u8 = @ptrCast(@alignCast(gpu_output_buffer.getMappedRange(0, output_size).?));
        defer gpu_output_buffer.unmap();
        const raw_output_bytes: []const u8 = buf[0..output_size]; // Keep as byte slice for accurate indexing

        const view_width: usize = @intCast(output_extent.width);
        const view_height: usize = @intCast(output_extent.height);

        // Calculate the aligned stride in terms of RGBA pixels for CPU-side reading
        // output_bytes_per_row is already the aligned bytes per row from the GPU copy.
        // We need to know how many RGBA structs that corresponds to.
        const output_pixel_stride: usize = output_bytes_per_row / @sizeOf(pixel.RGBA);

        for (0..view_height) |h| {
            // Calculate the starting byte offset for the current row, using the aligned stride
            const row_start_byte_offset = h * output_pixel_stride * @sizeOf(pixel.RGBA);

            // Calculate the ending byte offset for the *actual pixel data* in this row (unaligned width)
            const row_end_byte_offset = row_start_byte_offset + (view_width * @sizeOf(pixel.RGBA));

            // Extract the byte slice containing only the actual pixel data for this row
            // This prevents reading padding bytes as part of your image data.
            const row_bytes = raw_output_bytes[row_start_byte_offset..row_end_byte_offset];

            // Safely cast the row's bytes to a slice of pixel.RGBA
            const row_pixels: []const pixel.RGBA = @alignCast(std.mem.bytesAsSlice(pixel.RGBA, row_bytes));

            for (0..view_width) |w| {
                sfc.putPixel(@intCast(w), @intCast(h), .{ .rgba = row_pixels[w] });
            }
        }
        // --- END OF MODIFICATIONS FOR PIXEL COPY-BACK ---
    }
    fn handleBufferMap(status: wgpu.MapAsyncStatus, _: wgpu.StringView, userdata1: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {
        std.log.info("buffer_map status={x:.8}\n", .{@intFromEnum(status)});
        const complete: *bool = @ptrCast(@alignCast(userdata1));
        complete.* = true;
    }
};
