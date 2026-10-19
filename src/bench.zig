const std = @import("std");
const p = @import("precision.zig");
const Job = @import("worker.zig").Job;
pub fn main() !void {
    const cases = [_]struct { name: []const u8, preset: usize, zoom: f64, w: u32, h: u32, bla: bool = true }{
        .{ .name = "retina-seahorse-16", .preset = 1, .zoom = 16, .w = 1764, .h = 1388 },
        .{ .name = "retina-seahorse-24", .preset = 1, .zoom = 24, .w = 1764, .h = 1388 },
        .{ .name = "seahorse-64-no-BLA", .preset = 1, .zoom = 64, .w = 800, .h = 600, .bla = false },
        .{ .name = "seahorse-64-BLA", .preset = 1, .zoom = 64, .w = 800, .h = 600 },
        .{ .name = "overview", .preset = 0, .zoom = 0, .w = 800, .h = 600 },
        .{ .name = "seahorse", .preset = 1, .zoom = 24, .w = 800, .h = 600 },
        .{ .name = "deep-seahorse", .preset = 1, .zoom = 38, .w = 800, .h = 600 },
        .{ .name = "edge-4000-full", .preset = 3, .zoom = 4000, .w = 800, .h = 600 },
        .{ .name = "edge-1100", .preset = 3, .zoom = 1100, .w = 128, .h = 80 },
    };
    var engine: @import("engine.zig").Engine = .{};
    defer engine.deinit();
    for (cases) |case| {
        var cam = p.Camera.init();
        defer cam.deinit();
        cam.preset(case.preset);
        cam.zoom = case.zoom;
        cam.ensure();
        var times: [5]f64 = undefined;
        for (0..6) |run| {
            if (engine.gpu) |*gpu| gpu.use_bla = case.bla;
            const j = try Job.startCached(&engine, &cam, case.w, case.h, @intFromFloat(@max(1200, cam.zoom * 1.5 + 200)), 0, 1);
            j.thread.?.join();
            j.thread = null;
            defer j.destroy();
            if (j.failed or !j.gpu_used) return error.MetalBenchmarkUnavailable;
            if (run > 0) times[run - 1] = j.seconds * 1000;
            if (run == 5) std.debug.print("{s}: GPU={} exact={d} refined={d} refs={d} BLA-skips(first pixel)={d}; last prepare={d:.2}ms gpu+copy={d:.2}ms refine={d:.2}ms; ", .{ case.name, j.gpu_used, j.exact_pixels, j.refined_pixels, engine.references_built, if (engine.gpu) |g| g.last_skipped else 0, j.prepare_seconds * 1000, j.gpu_seconds * 1000, j.refine_seconds * 1000 });
        }
        std.mem.sort(f64, &times, {}, std.sort.asc(f64));
        std.debug.print("median={d:.3}ms range={d:.3}..{d:.3}ms\n", .{ times[2], times[0], times[4] });
    }
}
