//! Real-time, offscreen animation workload. Includes GPU readback, which the
//! windowed app does not need. No windows or synthetic screen input.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const State = @import("main.zig").State;
pub fn main() !void {
    for ([_]bool{ false, true }) |temporal| {
        try measure(16, 1, temporal);
        try measure(24, 1, temporal);
        try measure(16, -1, temporal);
        try measure(24, -1, temporal);
    }
}
fn measure(zoom: f64, direction: f64, temporal: bool) !void {
    var state = State.init();
    defer state.deinit();
    state.camera.preset(1);
    state.camera.zoom = zoom;
    state.camera.ensure();
    state.temporal = temporal;
    state.running = true;
    state.direction = direction;
    state.speed = 2;
    var tester: ui.Tester = undefined;
    try tester.init(std.heap.page_allocator, .init(&state, State.view), .{ .width = 1180, .height = 820, .scale = 2, .dark = true });
    defer tester.deinit();
    const deadline = ui.clock.now() + 10;
    while (state.frames.base == null and ui.clock.now() < deadline) {
        nanoui.runFor(0.005);
        tester.frame();
    }
    if (state.frames.base == null) return error.NoInitialFrame;
    const start_zoom = state.camera.zoom;
    var durations: [360]f64 = undefined;
    var min_step: f64 = 1;
    var min_density: f64 = 100;
    var moving_frames: usize = 0;
    var max_step: f64 = 0;
    const origin = ui.clock.now();
    const base_time = tester.time;
    var previous = origin - 1.0 / 120.0;
    for (&durations) |*duration| {
        const now = ui.clock.now();
        tester.time = base_time + now - origin;
        tester.dt = @floatCast(@min(0.05, now - previous));
        previous = now;
        const old_zoom = state.camera.zoom;
        tester.frame();
        const pixels = try tester.render(std.heap.page_allocator);
        pixels.deinit(std.heap.page_allocator);
        duration.* = (ui.clock.now() - now) * 1000;
        const step = (state.camera.zoom - old_zoom) * direction;
        if (step > 0) moving_frames += 1;
        const frame = state.frames.base.?;
        const factor = std.math.exp2(state.camera.zoom - frame.camera.zoom);
        const density = @min(@as(f64, @floatFromInt(frame.width)) / (frame.viewport.w * 2 * factor), @as(f64, @floatFromInt(frame.height)) / (frame.viewport.h * 2 * factor));
        if (factor < 1 - 1e-9) return error.UncoveredEdges;
        if (density < 1.15 - 1e-5) return error.UndersampledFrame;
        min_density = @min(min_density, density);
        min_step = @min(min_step, step);
        max_step = @max(max_step, step);
        const remaining = 1.0 / 120.0 - (ui.clock.now() - now);
        if (remaining > 0) nanoui.runFor(remaining);
    }
    const elapsed = ui.clock.now() - origin;
    std.mem.sort(f64, &durations, {}, std.sort.asc(f64));
    std.debug.print("reuse={} zoom 2^{d:.0}, {d}/360 moving Retina frames, min density={d:.3}: median={d:.2}ms p95={d:.2}ms max={d:.2}ms; zoom change {d:.3}; step min={d:.6} max={d:.6}; rate={d:.3} oct/s reused={d} GPU={} render={d:.2}ms\n", .{ temporal, zoom, moving_frames, min_density, durations[180], durations[342], durations[359], state.camera.zoom - start_zoom, min_step, max_step, @abs(state.camera.zoom - start_zoom) / elapsed, state.reused_pixels, state.gpu_used, state.render_seconds * 1000 });
    try tester.screenshot(if (zoom == 16) "/tmp/mandel-motion.png" else "/tmp/mandel-motion-deep.png");
}
