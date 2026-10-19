const std = @import("std");
const p = @import("precision.zig");
const f = @import("fractal.zig");
const GPU = @import("compute.zig").GPU;
const Reference = @import("reference.zig").Reference;
test "Metal matches MPFR on sampled ordinary, deep and rescaled viewports" {
    var gpu = try GPU.init();
    defer gpu.deinit();
    const cases = [_]struct { preset: usize, zoom: f64 }{ .{ .preset = 0, .zoom = 0 }, .{ .preset = 1, .zoom = 16 }, .{ .preset = 2, .zoom = 8 }, .{ .preset = 1, .zoom = 24 }, .{ .preset = 1, .zoom = 38 }, .{ .preset = 1, .zoom = 64 }, .{ .preset = 3, .zoom = 96 }, .{ .preset = 3, .zoom = 100.01 }, .{ .preset = 3, .zoom = 1100 }, .{ .preset = 3, .zoom = 4000 } };
    for (cases, 0..) |case, rev| {
        var cam = p.Camera.init();
        defer cam.deinit();
        cam.preset(case.preset);
        cam.zoom = case.zoom;
        cam.ensure();
        const limit: u32 = @intFromFloat(@max(if (case.preset == 1) @as(f64, 3600) else 1200, case.zoom * 1.5 + 200));
        var cancel = std.atomic.Value(bool).init(false);
        var rows = std.atomic.Value(u32).init(0);
        var ref = try Reference.init(&cam, limit, &cancel);
        defer ref.deinit();
        const w = 41;
        const h = 27;
        try gpu.run(&cam, ref.orbit[0..ref.count], rev, w, h, limit, 0, &cancel, &rows);
        if (case.zoom == 64) try std.testing.expect(gpu.last_skipped > 100);
        var exact = f.Exact.init(&cam);
        defer exact.deinit();
        var compared: usize = 0;
        var mismatches: usize = 0;
        var refined: usize = 0;
        for (gpu.values(w * h), 0..) |gpu_value, i| {
            if (i % 3 != 0) continue;
            var actual: f64 = gpu_value;
            const dx = (@as(f64, @floatFromInt(i % w)) + 0.5) / w - 0.5;
            const dy = (@as(f64, @floatFromInt(i / w)) + 0.5 - h * 0.5) / w;
            exact.coordinate(&cam, dx, dy);
            const expected = exact.sample(limit, null).?;
            if (gpu_value == -2) {
                refined += 1;
                const exponent: i32 = -@as(i32, @intFromFloat(@floor(cam.zoom)));
                const mantissa = 3.4 * std.math.exp2(-(cam.zoom - @floor(cam.zoom)));
                const cpu = if (cam.zoom < 8) f.direct(cam.x.double() + dx * exact.scale.double(), cam.y.double() - dy * exact.scale.double(), limit) else @import("scaled.zig").sample(ref.orbit[0..ref.count], dx * mantissa, -dy * mantissa, exponent, limit) orelse @import("wide.zig").sample(ref.orbit[0..ref.count], ref.low[0..ref.count], dx, -dy, mantissa, exponent, limit) orelse expected;
                actual = if (cpu.escaped) cpu.smooth else -1;
            }
            compared += 1;
            if (expected.escaped != (actual >= 0) or (expected.escaped and @abs(expected.smooth - actual) > 0.02)) {
                mismatches += 1;
                std.debug.print(" mismatch pixel={d} expected={d:.8} escaped={} actual={d:.8}\n", .{ i, expected.smooth, expected.escaped, actual });
            }
        }
        try std.testing.expectEqual(@as(usize, 369), compared);
        try std.testing.expect(refined < compared);
        try std.testing.expectEqual(@as(usize, 0), mismatches);
    }
}
test "reference cache survives zoom changes and rebuilds on pan" {
    var engine: @import("engine.zig").Engine = .{ .cpu_only = true };
    defer engine.deinit();
    var cam = p.Camera.init();
    defer cam.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    try engine.prepare(&cam, 1200, &cancel);
    cam.zoom = 100;
    cam.ensure();
    try engine.prepare(&cam, 1500, &cancel);
    try std.testing.expectEqual(@as(usize, 1), engine.references_built);
    cam.pan(0.1, 0);
    try engine.prepare(&cam, 1500, &cancel);
    try std.testing.expectEqual(@as(usize, 2), engine.references_built);
}

test "temporal reuse matches fresh rendering and rejects incompatible views" {
    const Job = @import("worker.zig").Job;
    var temporal: @import("engine.zig").Engine = .{};
    defer temporal.deinit();
    var fresh: @import("engine.zig").Engine = .{};
    defer fresh.deinit();
    var cam = p.Camera.init();
    defer cam.deinit();
    cam.preset(1);
    for ([_][2]u32{ .{ 129, 97 }, .{ 131, 99 }, .{ 129, 131 }, .{ 131, 129 } }) |case| {
        temporal.reuse.deinit();
        const w = case[0];
        const h = case[1];
        for ([_]f64{ 16, 17, 16, 16.25, 17.25, 16.25 }, 0..) |zoom, frame| {
            cam.zoom = zoom;
            cam.ensure();
            const reused = try Job.startTemporal(&temporal, &cam, w, h, 1200, 0, 1);
            defer reused.destroy();
            reused.thread.?.join();
            reused.thread = null;
            try std.testing.expect(!reused.failed and reused.gpu_used);
            try std.testing.expectEqual(@as(usize, if (frame == 0 or frame == 3) 0 else (2 * (w / 4) + 1) * (2 * (h / 4) + 1)), reused.reused_pixels);
            const baseline = try Job.startCached(&fresh, &cam, w, h, 1200, 0, 1);
            defer baseline.destroy();
            baseline.thread.?.join();
            baseline.thread = null;
            try std.testing.expect(!baseline.failed and baseline.gpu_used);
            for (reused.gpu_values.?, baseline.gpu_values.?, 0..) |actual, expected, pixel| {
                if ((expected < 0) != (actual < 0) or @abs(actual - expected) >= 0.02) std.debug.print("temporal mismatch frame={d} pixel={d} actual={d} expected={d} reused={d}\n", .{ frame, pixel, actual, expected, reused.reused_pixels });
                try std.testing.expectEqual(expected < 0, actual < 0);
                try std.testing.expect(@abs(actual - expected) < 0.02);
            }
        }
    }
    // The last completed image uses the final dimensions above.
    const w = 131;
    const h = 129;
    cam.zoom = 17.25;
    try std.testing.expectEqual(@as(i32, 1), temporal.reuse.direction(&cam, w, h, 1200, 0));
    try std.testing.expectEqual(@as(i32, 0), temporal.reuse.direction(&cam, w, h, 1201, 0));
    try std.testing.expectEqual(@as(i32, 0), temporal.reuse.direction(&cam, w, h, 1200, 1));
    try std.testing.expectEqual(@as(i32, 0), temporal.reuse.direction(&cam, w + 2, h, 1200, 0));
    cam.pan(0.001, 0);
    try std.testing.expectEqual(@as(i32, 0), temporal.reuse.direction(&cam, w, h, 1200, 0));
}
