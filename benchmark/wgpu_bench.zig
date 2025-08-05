const std = @import("std");
const z2d = @import("z2d");

//TODO: build script bench output etc fix dashed lines

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const runs = 10;
    const extents: []const i32 = &.{
        300,
        600,
        1200,
    };
    std.debug.print("benchmark:\ncomparing cpu based rendering to gpu rendering\nequal fixed random seed\nmeasurements are averaged over {d} runs\nkeep in mind the results are hardware and driver dependent!\n", .{runs});
    for (extents) |ext| {
        const run = try benchmark(gpa.allocator(), ext, runs);
        const tframe: f64 = 1_000_000;
        const cpu = @as(f64, @floatFromInt(run.cpu_avg_ns)) / tframe;
        const gpu = @as(f64, @floatFromInt(run.gpu_avg_ns)) / tframe;
        std.debug.print("extent {d}x{d}, cpu: {d:.3} ms gpu: {d:3}ms\n", .{ ext, ext, cpu, gpu });
    }
}
const GpuContext = z2d.ContextWgpu;
const CpuContext = z2d.Context;

fn clear(sfc: *z2d.Surface) void {
    const width: usize = @intCast(sfc.getWidth());
    const height: usize = @intCast(sfc.getHeight());
    for (0..width) |w| {
        for (0..height) |h| {
            sfc.putPixel(@intCast(w), @intCast(h), z2d.Pixel.fromColor(.{ .rgba = .{ 0, 0, 0, 0 } }));
        }
    }
}

fn benchmark(alloc: std.mem.Allocator, size: i32, comptime runs: usize) !struct {
    cpu_avg_ns: u64,
    gpu_avg_ns: u64,
} {
    var gpu_times: [runs]u64 = std.mem.zeroes([runs]u64);
    var cpu_times: [runs]u64 = std.mem.zeroes([runs]u64);

    var cpu_rgen = std.Random.DefaultPrng.init(2342039854032);
    var cpu_ran = cpu_rgen.random();
    var gpu_rgen = std.Random.DefaultPrng.init(2342039854032);
    var gpu_ran = gpu_rgen.random();
    var sf = try z2d.Surface.init(.image_surface_rgba, alloc, size, size);
    defer sf.deinit(alloc);
    var timer = std.time.Timer.start() catch unreachable;

    std.fs.cwd().makeDir("benchmark/output") catch {};
    const workloops = 8;
    for (0..runs) |run| {
        var cpu_ctx = CpuContext.init(alloc, &sf);
        defer cpu_ctx.deinit();
        timer.reset();
        for (0..workloops) |_| try perf_test(&cpu_ctx, &cpu_ran);
        cpu_times[run] = timer.read();
        try z2d.png_exporter.writeToPNGFile(sf, "benchmark/output/bench-cpu.png", .{});
        clear(&sf);

        var gpu_ctx = try GpuContext.init(alloc, &sf, .default);
        defer gpu_ctx.deinit();
        timer.reset();
        for (0..workloops) |_| try perf_test(&gpu_ctx, &gpu_ran);
        try gpu_ctx.finalize();
        gpu_times[run] = timer.read();
        try z2d.png_exporter.writeToPNGFile(sf, "benchmark/output/bench-gpu.png", .{});
        clear(&sf);
    }
    var sum: u64 = undefined;

    sum = 0;
    for (&cpu_times) |tm| sum += tm;
    const cpu_average = sum / @as(u64, runs);
    sum = 0;
    for (&gpu_times) |tm| sum += tm;
    const gpu_average = sum / @as(u64, runs);
    return .{
        .cpu_avg_ns = cpu_average,
        .gpu_avg_ns = gpu_average,
    };
}

fn perf_test(ctx: anytype, ran: *std.Random) !void {
    // const r = ran.float(f64);
    // const g = ran.float(f64);
    // const b = ran.float(f64);
    const lw = ran.float(f64) * 10.0 + 1;
    const cap_mode = ran.enumValue(z2d.options.CapMode);
    const join_mode = ran.enumValue(z2d.options.JoinMode);

    ctx.setSourceToPixel(.{ .rgba = .fromClamped(1, 1, 1, 0.5) });
    ctx.setLineWidth(lw);
    ctx.setLineCapMode(cap_mode);
    ctx.setLineJoinMode(join_mode);

    const extent: f64 = @floatFromInt(ctx.surface.getWidth());
    for (0..12) |_| {
        const x = ran.float(f64) * extent;
        const y = ran.float(f64) * extent;
        try ctx.lineTo(x, y);
    }

    const stroke = ran.boolean();
    if (stroke) {
        try ctx.stroke();
    } else {
        try ctx.closePath();
        try ctx.fill();
    }
    ctx.resetPath();
}
