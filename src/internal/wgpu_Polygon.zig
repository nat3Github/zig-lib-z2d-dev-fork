const std = @import("std");
const debug = @import("std").debug;
const math = @import("std").math;
const mem = @import("std").mem;
const testing = @import("std").testing;

const FillRule = @import("../options.zig").FillRule;
const Point = @import("Point.zig");
const InternalError = @import("InternalError.zig").InternalError;

pub const PointF32 = extern struct {
    x: f32,
    y: f32,
    pub fn cast(self: @This()) Point {
        return Point{
            .x = @floatCast(self.x),
            .y = @floatCast(self.y),
        };
    }
    pub fn equal(self: @This(), other: PointF32) bool {
        return self.x == other.x and self.y == other.y;
    }
};
pub const Range = struct {
    start: usize,
    end: usize,
};

pub const WgpuPolygon = struct {
    points: std.ArrayList(PointF32),
    range: std.ArrayList(Range),
    current_contour_start_idx: usize = 0,

    pub fn init(alloc: std.mem.Allocator) @This() {
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

    pub fn last_current_point(self: *@This()) ?Point {
        if (self.current_contour_len() == 0) return null;
        return self.points.items[self.points.items.len - 1].cast();
    }

    pub fn first_current_point(self: *@This()) ?Point {
        if (self.current_contour_len() == 0) return null;
        return self.points.items[self.current_contour_start_idx].cast();
    }

    pub fn current_contour_len(self: *@This()) usize {
        return self.points.items.len - self.current_contour_start_idx;
    }
};
