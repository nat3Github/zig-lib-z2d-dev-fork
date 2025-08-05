//! `Context` represents the managed drawing interface to z2d. It holds a
//! `Path`, `Surface`, and `Pattern` that it uses for these operations and a
//! frontend for controlling various options for filling and stroking.
//!
//! Every field within `Context` is controllable via setters or other frontend
//! methods. It is recommended you do not manipulate these fields directly. If
//! you do wish further control over the process than what `Context` provides,
//! you can use each underlying component in an unmanaged fashion by following
//! the patterns used here as an example.
//!
//!
//! NOTE: API differences to Context:
//! Anti Alias mode must be decided upon creation
const WgpuContext = @This();

const mem = @import("std").mem;
const z2d = @import("z2d.zig");

const compositor = z2d.compositor;
const options = z2d.options;
const painter = @import("wgpu_painter.zig");

const text = z2d.text;

const Dither = z2d.compositor.Dither;
const Path = z2d.Path;
const Pixel = z2d.Pixel;
const Pattern = z2d.Pattern;
const Surface = z2d.Surface;
const Font = z2d.Font;
const Transformation = z2d.Transformation;

alloc: mem.Allocator,
path: Path,
surface: *Surface,
gpu_painter: painter.Painter,
pattern: Pattern = .{
    .opaque_pattern = .{
        .pixel = .{ .rgba = .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xFF } },
    },
},
font: union(enum) {
    none: void,
    file: Font,
    buffer: Font,
} = .none,

anti_aliasing_mode: options.AntiAliasMode = .default,
dashes: []const f64 = &.{},
dash_offset: f64 = 0,
dither: Dither.Type = .none,
fill_rule: options.FillRule = .non_zero,
font_size: f64 = 16.0,
line_cap_mode: options.CapMode = .butt,
line_join_mode: options.JoinMode = .miter,
line_width: f64 = 2.0,
miter_limit: f64 = 10.0,
operator: compositor.Operator = .src_over,
precision: compositor.Precision = .integer,
tolerance: f64 = options.default_tolerance,
transformation: Transformation = Transformation.identity,

/// Initializes a `Context` with the passed in allocator and surface. Call
/// `deinit` to release any resources managed solely by the context, such as
/// the managed `Path`.
pub fn init(alloc: mem.Allocator, surface: *Surface, anti_alias_mode: options.AntiAliasMode) !WgpuContext {
    return .{
        .alloc = alloc,
        .surface = surface,
        .path = .{},
        .gpu_painter = try painter.Painter.init(alloc, anti_alias_mode),
    };
}

pub fn finalize(self: *WgpuContext) !void {
    try self.gpu_painter.finalize(self.surface);
}

/// Releases all resources associated with this particular context, such as the
/// managed `Path`.
pub fn deinit(self: *WgpuContext) void {
    self.path.deinit(self.alloc);
    self.gpu_painter.deinit();
    self.path = undefined;
}

/// Releases any font data held on by the context.
fn deinitFont(self: *WgpuContext) void {
    switch (self.font) {
        .file => self.font.file.deinit(self.alloc),
        else => {},
    }
    self.font = .none;
}

/// Returns the current underlying `Pixel` for the context's pattern.
pub fn getSource(self: *WgpuContext) Pattern {
    return self.pattern;
}

/// Returns the current dither type set in the context.
pub fn getDither(self: *WgpuContext) Dither {
    return self.dither;
}

/// Sets the context's pattern to the pattern supplied; fill and stroke
/// operations will draw with this source when they are called.
///
/// The default pattern is an RGBA opaque black pixel source (the equivalent of
/// running `setSourceToPixel(.{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 }
/// })`).
///
/// Note that for patterns that take a transformation matrix (e.g., gradients),
/// this locks the current transformation matrix (CTM) to the gradient. Any
/// further changes to the CTM will not affect the pattern). Additionally, the
/// inverse of the CTM is applied, and the whole operation is a no-op if the
/// CTM is not invertible.
pub fn setSource(self: *WgpuContext, source: Pattern) void {
    switch (source) {
        .gradient => |g| g.setTransformation(self.transformation) catch return,
        else => {},
    }
    self.pattern = source;
}

/// Sets the context's pattern to the supplied `Pixel`. Fill and stroke
/// operations will draw with this pixel when they are called. The default
/// pattern is an RGBA opaque black pixel source (the equivalent of running
/// `setSourceToPixel(.{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 } })`).
pub fn setSourceToPixel(self: *WgpuContext, px: Pixel) void {
    self.pattern = .{ .opaque_pattern = .{ .pixel = px } };
}

/// Sets the dithering method to the method supplied. Dithering can be used to
/// apply noise to smooth out artifacts in patterns such as gradients (where it
/// prevents color banding).
pub fn setDither(self: *WgpuContext, dither: Dither.Type) void {
    self.dither = dither;
}

/// Returns the current fill rule for the context.
pub fn getFillRule(self: *WgpuContext) options.FillRule {
    return self.fill_rule;
}

/// Sets how edges are counted during fill operations. The default mode is
/// `.non_zero`.
pub fn setFillRule(self: *WgpuContext, fill_rule: options.FillRule) void {
    self.fill_rule = fill_rule;
}

/// Returns the current line cap mode for the context.
pub fn getLineCapMode(self: *WgpuContext) options.CapMode {
    return self.line_cap_mode;
}

/// Sets how the ends of lines are drawn during stroke operations, a process
/// known as "capping". The default cap mode is `.butt`.
pub fn setLineCapMode(self: *WgpuContext, line_cap_mode: options.CapMode) void {
    self.line_cap_mode = line_cap_mode;
}

/// Returns the current line join mode for the context.
pub fn getLineJoinMode(self: *WgpuContext) options.JoinMode {
    return self.line_join_mode;
}

/// Sets how lines are joined during stroke operations. The default join mode
/// is `.miter`.
pub fn setLineJoinMode(self: *WgpuContext, line_join_mode: options.JoinMode) void {
    self.line_join_mode = line_join_mode;
}

/// Returns the current line width for the context.
pub fn getLineWidth(self: *WgpuContext) f64 {
    return self.line_width;
}

/// Sets the line width for stroking operations, in pixels. This value is taken
/// at call time of `stroke`, and has no effect during path construction.
pub fn setLineWidth(self: *WgpuContext, line_width: f64) void {
    self.line_width = line_width;
}

/// Returns the current dash array for the context.
pub fn getDashes(self: *WgpuContext) []const f64 {
    return self.dashes;
}

/// Sets the dash array for this context.
///
/// The dash array is a set of lengths representing segments that will draw a
/// stroke using dashed lines. Drawing will alternate between "on" (dashed) and
/// "off" (gapped), traversing over the array and wrapping after the last
/// element.
///
/// Single and odd element lengths are allowed. In these cases, the wrapping
/// effect will either alternate between even-lengthed dashes and gaps in the
/// single-element case, or give dashes of varying lengths and gaps otherwise.
///
/// Zero length segments (as long as they are accompanied by other non-zero,
/// non-negative segments) are allowed, in these cases, a dot (round cap) or
/// square (square cap) will be made at the location of the dash stop, in the
/// latter case, the square will be aligned to the direction of the current
/// line segment.
///
/// If this value contains a negative number, or if all values are zero, or if
/// the slice is empty (the default), dashing is disabled and this value is
/// ignored.
pub fn setDashes(self: *WgpuContext, dashes: []const f64) void {
    self.dashes = dashes;
}

/// Returns the current dash offset for the context.
pub fn getDashOffset(self: *WgpuContext) f64 {
    return self.dash_offset;
}

/// Sets the dash offset for dashed lines (when `setDashes` has been called
/// with a valid dash value).
///
/// The effect depends on whether or not a positive or negative value has been
/// supplied. Positive values "pull", which fast-forwards the dash state,
/// giving the effect of "pulling" the line in. Negative values "push", which
/// rewinds the dash state, giving the effect of "pushing" the line out.
///
/// A value of 0 (the default) provides no effect and the pattern runs as
/// normal.
pub fn setDashOffset(self: *WgpuContext, dash_offset: f64) void {
    self.dash_offset = dash_offset;
}

/// Returns the current miter limit for the context.
pub fn getMiterLimit(self: *WgpuContext) f64 {
    return self.miter_limit;
}

/// Sets the limit when the line join mode set with `setLineJoinMode` is
/// `.miter`; in this mode, this value determines when the join is instead
/// drawn as a bevel. This can be used to prevent extremely large miter points
/// that result from very sharp angled joins.
///
/// The value here is the maximum allowed ratio of the miter distance (the
/// distance of the center of the stroke to the miter point) divided by the
/// line width. This is also described by 1 / sin(Θ / 2), where Θ is the
/// interior angle.
///
/// The default limit is 10.0, which sets the cutoff at ~11 degrees. A miter
/// limit of 2.0 translates to ~60 degrees, and a limit of 1.414 translates to
/// ~90 degrees.
pub fn setMiterLimit(self: *WgpuContext, miter_limit: f64) void {
    self.miter_limit = miter_limit;
}

/// Returns the current compositing operator for this context.
pub fn getOperator(self: *WgpuContext) compositor.Operator {
    return self.operator;
}

/// Sets the compositing operator to be used for drawing operations. The
/// default operator is `.src_over`.
pub fn setOperator(self: *WgpuContext, op: compositor.Operator) void {
    self.operator = op;
}

/// Returns the current compositing precision for this context.
pub fn getPrecision(self: *WgpuContext) compositor.Precision {
    return self.precision;
}

/// Sets the compositing precision to be used for fill and stroke, which
/// controls the accuracy of color operations. The default precision is
/// `.integer`. Some operators require `.float`; if an operator is detected
/// that requires it, the precision will be changed.
pub fn setPrecision(self: *WgpuContext, precision: compositor.Precision) void {
    self.precision = precision;
}

/// Returns the current error tolerance for the context.
pub fn getTolerance(self: *WgpuContext) f64 {
    return self.tolerance;
}

/// Sets the maximum error tolerance used for approximating curves and arcs. A
/// higher tolerance will give better performance, but "blockier" curves. The
/// default tolerance is 0.1, and values below this are unlikely to give better
/// visual results. This value has a minimum of 0.001, values below this are
/// clamped.
///
/// Note that this setting also affects the "virtual pen" used to draw rounded
/// caps and joins, which use static vertices for plotting. This can produce
/// marked artifacts at relatively low tolerance settings, so take care when
/// changing under these scenarios.
pub fn setTolerance(self: *WgpuContext, tolerance: f64) void {
    const t = @max(tolerance, 0.001);
    self.tolerance = t;
    self.path.tolerance = t;
}

/// Determines the source type to use when setting the font.
pub const SetFontSource = union(enum) {
    /// Load from a file at the supplied path. The contents of the file are
    /// read into memory using the context's allocator and freed when `deinit`
    /// is called, or if the font is switched via another `setFont` call.
    file: []const u8,

    /// Load from a supplied buffer of externally managed memory.
    buffer: []const u8,
};

/// Sets the font to use with `showText`, loading the file form the supplied
/// path. The contents of the file are read into memory using the context's
/// allocator and freed when `deinit` is called, or if the font is switched via
/// another `setFontToFile` or `setFontToBuffer` call.
pub fn setFontToFile(self: *WgpuContext, filename: []const u8) Font.LoadFileError!void {
    self.deinitFont();
    self.font = .{ .file = try Font.loadFile(self.alloc, filename) };
}

/// Sets the font to use with `showText`, using a supplied buffer of externally
/// managed memory.
pub fn setFontToBuffer(self: *WgpuContext, buffer: []const u8) Font.LoadBufferError!void {
    self.deinitFont();
    self.font = .{ .file = try Font.loadBuffer(buffer) };
}

/// Returns the font size set with `setFont`.
pub fn getFontSize(self: *WgpuContext) f64 {
    return self.font_size;
}

/// Sets the font size to use with `showText`, in pixels.
///
/// To translate from points, use `target_dpi / 72 * point_size`. The default
/// is 16px, or 12pt @ 96 DPI.
pub fn setFontSize(self: *WgpuContext, size: f64) void {
    self.font_size = size;
}

/// Returns the current transformation matrix (CTM) for the context.
pub fn getTransformation(self: *WgpuContext) Transformation {
    return self.transformation;
}

/// Modifies the current transformation matrix (CTM) by setting it equal to the
/// supplied matrix.
pub fn setTransformation(self: *WgpuContext, transformation: Transformation) void {
    self.transformation = transformation;
    self.path.transformation = transformation;
}

/// Modifies the current transformation matrix (CTM) to the identity matrix
/// (i.e., no transformation takes place).
pub fn setIdentity(self: *WgpuContext) void {
    self.setTransformation(Transformation.identity);
}

/// Modifies the current transformation matrix (CTM) by multiplying it with the
/// supplied matrix.
pub fn mul(self: *WgpuContext, a: Transformation) void {
    self.setTransformation(self.getTransformation().mul(a));
}

/// Modifies the current transformation matrix (CTM) by applying a co-ordinate
/// offset to the origin.
pub fn translate(self: *WgpuContext, tx: f64, ty: f64) void {
    self.setTransformation(self.getTransformation().translate(tx, ty));
}

/// Modifies the current transformation matrix (CTM) by rotating around the
/// origin by `angle` (in radians).
pub fn rotate(self: *WgpuContext, angle: f64) void {
    self.setTransformation(self.getTransformation().rotate(angle));
}

/// Modifies the current transformation matrix (CTM) by scaling by (`sx`,
/// `sy`). When `sx` and `sy` are not equal, a stretching effect will be
/// achieved.
pub fn scale(self: *WgpuContext, sx: f64, sy: f64) void {
    self.setTransformation(self.getTransformation().scale(sx, sy));
}

/// Applies the current transformation matrix (CTM) to the supplied `x` and `y`.
pub fn userToDevice(self: *WgpuContext, x: *f64, y: *f64) void {
    self.transformation.userToDevice(x, y);
}

/// Applies the current transformation matrix (CTM) to the supplied `x` and
/// `y`, but ignores translation.
pub fn userToDeviceDistance(self: *WgpuContext, x: *f64, y: *f64) void {
    self.transformation.userToDeviceDistance(x, y);
}

/// Applies the inverse of the current transformation matrix (CTM) to the
/// supplied `x` and `y`.
pub fn deviceToUser(self: *WgpuContext, x: *f64, y: *f64) Transformation.Error!void {
    try self.transformation.deviceToUser(x, y);
}

/// Applies the inverse of the current transformation matrix (CTM) to the
/// supplied `x` and `y`, but ignores translation.
pub fn deviceToUserDistance(self: *WgpuContext, x: *f64, y: *f64) Transformation.Error!void {
    try self.transformation.deviceToUserDistance(x, y);
}

/// Rests the path set, clearing all nodes and state.
pub fn resetPath(self: *WgpuContext) void {
    self.path.reset();
}

/// Starts a new path, and moves the current point to it. If a path already has
/// been started, a new sub-path is started. Note that this does not clear any
/// existing paths or nodes, use `resetPath` to accomplish this.
pub fn moveTo(self: *WgpuContext, x: f64, y: f64) mem.Allocator.Error!void {
    try self.path.moveTo(self.alloc, x, y);
}

/// Begins a new sub-path relative to the current point. It is an error to call
/// this without a current point.
pub fn relMoveTo(self: *WgpuContext, x: f64, y: f64) (Path.Error || mem.Allocator.Error)!void {
    try self.path.relMoveTo(self.alloc, x, y);
}

/// Draws a line from the current point to the specified point and sets
/// it as the current point. Acts as a `moveTo` instead if there is no
/// current point.
pub fn lineTo(self: *WgpuContext, x: f64, y: f64) mem.Allocator.Error!void {
    try self.path.lineTo(self.alloc, x, y);
}

/// Draws a line relative to the current point. It is an error to call this
/// without a current point.
pub fn relLineTo(self: *WgpuContext, x: f64, y: f64) (Path.Error || mem.Allocator.Error)!void {
    try self.path.relLineTo(self.alloc, x, y);
}

/// Draws a cubic bezier with the three supplied control points from the
/// current point. The new current point is set to (`x3`, `y3`). It is an error
/// to call this without a current point.
pub fn curveTo(
    self: *WgpuContext,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    x3: f64,
    y3: f64,
) (Path.Error || mem.Allocator.Error)!void {
    try self.path.curveTo(self.alloc, x1, y1, x2, y2, x3, y3);
}

/// Draws a cubic bezier relative to the current point. It is an error to call
/// this without a current point.
pub fn relCurveTo(
    self: *WgpuContext,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    x3: f64,
    y3: f64,
) (Path.Error || mem.Allocator.Error)!void {
    try self.path.relCurveTo(self.alloc, x1, y1, x2, y2, x3, y3);
}

/// Adds a circular arc of the given radius to the current path. The arc is
/// centered at (`xc`, `yc`), begins at `angle1` and proceeds in the direction
/// of increasing angles (i.e., counterclockwise direction) to end at `angle2`.
///
/// If `angle2` is less than `angle1`, it will be increased by 2 * Π until it's
/// greater than `angle1`.
///
/// Angles are measured at radians (to convert from degrees, multiply by Π /
/// 180).
///
/// If there's a current point, an initial line segment will be added to the
/// path to connect the current point to the beginning of the arc. If this
/// behavior is undesired, call `resetPath` before calling. This will trigger a
/// `moveTo` before the splines are plotted, creating a new subpath.
///
/// After this operation, the current point will be the end of the arc.
///
/// ## Drawing an ellipse
///
/// In order to draw an ellipse, use `arc` along with a transformation. The
/// following example will draw an elliptical arc at (`x`, `y`) bounded by the
/// rectangle of `width` by `height` (i.e., the rectangle controls the lengths
/// of the radii).
///
/// ```
/// const saved_ctm = context.getTransformation();
/// context.translate(x + width / 2, y + height / 2);
/// context.scale(width / 2, height / 2);
/// try context.arc(0, 0, 1, 0, 2 * math.pi);
/// context.setTransformation(saved_ctm);
/// ```
///
pub fn arc(
    self: *WgpuContext,
    xc: f64,
    yc: f64,
    radius: f64,
    angle1: f64,
    angle2: f64,
) (Path.Error || mem.Allocator.Error)!void {
    try self.path.arc(self.alloc, xc, yc, radius, angle1, angle2);
}

/// Like `arc`, but draws in the reverse direction, i.e., begins at `angle1`,
/// and moves in decreasing angles (i.e., counterclockwise direction) to end at
/// `angle2`. If `angle2` is greater than `angle1`, it will be decreased by 2 *
/// Π until it's less than `angle1`.
pub fn arcNegative(
    self: *WgpuContext,
    xc: f64,
    yc: f64,
    radius: f64,
    angle1: f64,
    angle2: f64,
) (Path.Error || mem.Allocator.Error)!void {
    try self.path.arcNegative(self.alloc, xc, yc, radius, angle1, angle2);
}

/// Closes the path by drawing a line from the current point by the
/// starting point. No effect if there is no current point.
pub fn closePath(self: *WgpuContext) mem.Allocator.Error!void {
    try self.path.close(self.alloc);
}

/// Returns `true` if all subpaths in the context's path set are currently
/// closed.
pub fn isPathClosed(self: *WgpuContext) bool {
    return self.path.isClosed();
}

/// Runs a fill operation for the current path and any subpaths. All paths in
/// the set must be closed. This is a no-op if there are no nodes.
pub fn fill(self: *WgpuContext) !void {
    const wrapped_pattern = self.wrapDither();
    try self.gpu_painter.fill(
        &wrapped_pattern,
        self.path.nodes.items,
        .{
            .anti_aliasing_mode = self.anti_aliasing_mode,
            .fill_rule = self.fill_rule,
            .operator = self.operator,
            .precision = self.precision,
            .tolerance = self.tolerance,
        },
    );
}

/// Strokes a line for the current path and any subpaths.
///
/// The behavior of open and closed paths are different for stroking. For open
/// paths (not explicitly closed with `closePath`), the start and the end of
/// the line are capped using the style set with `setLineCapMode`. For closed
/// paths (ones that *are* explicitly closed with `closePath`), the
/// intersection joint of the start and end are instead joined, as with with
/// all other joints along the way, with the style set in `setLineJoinMode`.
///
/// This is a no-op if there are no nodes.
pub fn stroke(self: *WgpuContext) !void {
    const wrapped_pattern = self.wrapDither();
    try self.gpu_painter.stroke(
        &wrapped_pattern,
        self.path.nodes.items,
        .{
            .anti_aliasing_mode = self.anti_aliasing_mode,
            .dashes = self.dashes,
            .dash_offset = self.dash_offset,
            .line_cap_mode = self.line_cap_mode,
            .line_join_mode = self.line_join_mode,
            .line_width = self.line_width,
            .miter_limit = self.miter_limit,
            .operator = self.operator,
            .precision = self.precision,
            .tolerance = self.tolerance,
            .transformation = self.transformation,
        },
    );
}

/// Shows the text from the UTF-8 supplied string at the co-ordinates specified
/// by `(x, y)`.
///
/// Note that the current transformation matrix, font size, and options that
/// would normally apply to fill operations are applied to the rendering of
/// text.
///
/// See the `text` package and `Font` type for details on loading in fonts.
pub fn showText(self: *WgpuContext, utf8: []const u8, x: f64, y: f64) text.ShowTextError!void {
    const font: *Font = switch (self.font) {
        inline .file, .buffer => |*f| f,
        else => return,
    };
    const wrapped_pattern = self.wrapDither();
    try text.show(
        self.alloc,
        self.surface,
        &wrapped_pattern,
        font,
        utf8,
        x,
        y,
        .{
            .transformation = self.transformation,
            .size = self.font_size,
            .fill_opts = .{
                .anti_aliasing_mode = self.anti_aliasing_mode,
                .fill_rule = self.fill_rule,
                .operator = self.operator,
                .precision = self.precision,
                .tolerance = self.tolerance,
            },
        },
    );
}

fn wrapDither(self: *WgpuContext) Pattern {
    return switch (self.dither) {
        .none => self.pattern,
        else => .{
            .dither = .{
                .type = self.dither,
                .source = switch (self.pattern) {
                    .opaque_pattern => |p| .{ .pixel = p.pixel },
                    .gradient => |g| .{ .gradient = g },
                    else => return self.pattern,
                },
                .scale = switch (self.surface.*) {
                    .image_surface_alpha1 => 1,
                    .image_surface_alpha2 => 2,
                    .image_surface_alpha4 => 4,
                    else => 8,
                },
            },
        },
    };
}

// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi
