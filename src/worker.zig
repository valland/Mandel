const std = @import("std");
const p = @import("precision.zig");
const f = @import("fractal.zig");
const scaled = @import("scaled.zig");
const ui = @import("nanoui").ui;
pub const Engine = @import("engine.zig").Engine;
pub const Job = struct {
    camera: p.Camera,
    width: u32,
    height: u32,
    limit: u32,
    palette: usize,
    generation: u64,
    pixels: []u8,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    rows: std.atomic.Value(u32) = .init(0),
    seconds: f64 = 0,
    prepare_seconds: f64 = 0,
    gpu_seconds: f64 = 0,
    refine_seconds: f64 = 0,
    exact_pixels: usize = 0,
    unresolved_pixels: usize = 0,
    refined_pixels: usize = 0,
    failed: bool = false,
    gpu_used: bool = false,
    temporal: bool = false,
    reused_pixels: usize = 0,
    engine: ?*Engine = null,
    next_row: std.atomic.Value(u32) = .init(0),
    exact_count: std.atomic.Value(usize) = .init(0),
    unresolved_count: std.atomic.Value(usize) = .init(0),
    refined_count: std.atomic.Value(usize) = .init(0),
    orbit: []const f.Complex = &.{},
    orbit_low: []const f.Complex = &.{},
    gpu_values: ?[]f32 = null,
    colors: [4096][4]u8 = undefined,
    pub fn start(cam: *const p.Camera, w: u32, h: u32, limit: u32, palette: usize, generation: u64) !*Job {
        return startCached(null, cam, w, h, limit, palette, generation);
    }
    pub fn startCached(engine: ?*Engine, cam: *const p.Camera, w: u32, h: u32, limit: u32, palette: usize, generation: u64) !*Job {
        return startJob(engine, cam, w, h, limit, palette, generation, false);
    }
    pub fn startTemporal(engine: *Engine, cam: *const p.Camera, w: u32, h: u32, limit: u32, palette: usize, generation: u64) !*Job {
        return startJob(engine, cam, w, h, limit, palette, generation, true);
    }
    fn startJob(engine: ?*Engine, cam: *const p.Camera, w: u32, h: u32, limit: u32, palette: usize, generation: u64, temporal: bool) !*Job {
        const gpa = std.heap.page_allocator;
        const j = try gpa.create(Job);
        errdefer gpa.destroy(j);
        const pixels = try gpa.alloc(u8, w * h * 4);
        errdefer gpa.free(pixels);
        j.* = .{ .camera = cam.clone(), .width = w, .height = h, .limit = limit, .palette = palette, .generation = generation, .pixels = pixels, .engine = engine, .temporal = temporal };
        errdefer j.camera.deinit();
        j.thread = try std.Thread.spawn(.{}, render, .{j});
        return j;
    }
    pub fn destroy(j: *Job) void {
        j.cancel.store(true, .release);
        if (j.thread) |t| t.join();
        j.camera.deinit();
        std.heap.page_allocator.free(j.pixels);
        std.heap.page_allocator.destroy(j);
    }
    fn render(j: *Job) void {
        const start_time = ui.clock.now();
        defer {
            j.seconds = ui.clock.now() - start_time;
            j.done.store(true, .release);
        }
        defer p.c.mpfr_free_cache();
        var local: Engine = .{ .cpu_only = true };
        defer local.deinit();
        const engine = j.engine orelse &local;
        engine.prepare(&j.camera, j.limit, &j.cancel) catch |err| {
            if (err != error.Cancelled) j.failed = true;
            return;
        };
        j.prepare_seconds = ui.clock.now() - start_time;
        const ref = &engine.reference.?;
        j.orbit = ref.orbit[0..ref.count];
        j.orbit_low = ref.low[0..ref.count];
        for (&j.colors, 0..) |*out, i| out.* = f.color(.{ .iterations = 0, .escaped = true, .smooth = @as(f64, @floatFromInt(i)) / (4096 * 0.026) }, j.palette);
        const gpu_start = ui.clock.now();
        if (!j.temporal) engine.reuse.deinit();
        if (engine.gpu) |*gpu| {
            gpu.reuse = if (j.temporal) &engine.reuse else null;
            gpu.run(&j.camera, j.orbit, engine.revision, j.width, j.height, j.limit, j.palette, &j.cancel, &j.rows) catch |err| {
                if (err == error.Cancelled) return;
                std.log.warn("Metal compute failed ({s}); retrying on CPU", .{@errorName(err)});
                gpu.deinit();
                engine.gpu = null;
            };
            if (engine.gpu) |*ready| {
                j.gpu_used = true;
                j.reused_pixels = ready.last_reused;
                const count = @as(usize, j.width) * j.height;
                @memcpy(j.pixels, ready.bytes(count));
                j.gpu_values = ready.values(count);
            }
        }
        j.gpu_seconds = ui.clock.now() - gpu_start;
        if (j.cancel.load(.acquire)) return;
        const refine_start = ui.clock.now();
        j.rows.store(0, .release);
        const cores = std.Thread.getCpuCount() catch 4;
        const count = @min(12, if (cores > 2) cores - 2 else 1);
        var threads: [11]std.Thread = undefined;
        var spawned: usize = 0;
        for (0..count - 1) |_| {
            threads[spawned] = std.Thread.spawn(.{}, renderRows, .{j}) catch break;
            spawned += 1;
        }
        renderRows(j);
        for (threads[0..spawned]) |t| t.join();
        j.refine_seconds = ui.clock.now() - refine_start;
        j.unresolved_pixels = j.unresolved_count.load(.acquire);
        j.exact_pixels = j.exact_count.load(.acquire);
        j.refined_pixels = j.refined_count.load(.acquire);
        if (j.temporal and !j.cancel.load(.acquire)) if (j.gpu_values) |values| {
            engine.reuse.save(&j.camera, j.width, j.height, j.limit, j.palette, j.pixels, values) catch engine.reuse.deinit();
        };
    }
    fn renderRows(j: *Job) void {
        defer p.c.mpfr_free_cache();
        var exact = f.Exact.init(&j.camera);
        defer exact.deinit();
        const exponent: i32 = -@as(i32, @intFromFloat(@floor(j.camera.zoom)));
        const mantissa = 3.4 * std.math.exp2(-(j.camera.zoom - @floor(j.camera.zoom)));
        const span = exact.scale.double();
        var unresolved: usize = 0;
        var exact_count: usize = 0;
        var refined: usize = 0;
        defer {
            _ = j.unresolved_count.fetchAdd(unresolved, .release);
            _ = j.exact_count.fetchAdd(exact_count, .release);
            _ = j.refined_count.fetchAdd(refined, .release);
        }
        while (true) {
            const row = j.next_row.fetchAdd(4, .monotonic);
            if (row >= j.height) return;
            for (row..@min(row + 4, j.height)) |y| {
                if (j.cancel.load(.acquire)) return;
                for (0..j.width) |x| {
                    const index = y * j.width + x;
                    if (j.gpu_values) |values| {
                        if (values[index] != -2) {
                            if (values[index] < 0) unresolved += 1;
                            continue;
                        }
                        refined += 1;
                    }
                    if (j.cancel.load(.monotonic)) return;
                    const dx = (@as(f64, @floatFromInt(x)) + 0.5 - @as(f64, @floatFromInt(j.width)) * 0.5) / @as(f64, @floatFromInt(j.width));
                    const dy = (@as(f64, @floatFromInt(y)) + 0.5 - @as(f64, @floatFromInt(j.height)) * 0.5) / @as(f64, @floatFromInt(j.width));
                    const fast: ?f.Sample = if (j.camera.zoom < 8) f.direct(j.camera.x.double() + dx * span, j.camera.y.double() - dy * span, j.limit) else scaled.sample(j.orbit, dx * mantissa, -dy * mantissa, exponent, j.limit);
                    const precise = fast orelse @import("wide.zig").sample(j.orbit, j.orbit_low, dx, -dy, mantissa, exponent, j.limit);
                    const sample = precise orelse blk: {
                        exact_count += 1;
                        exact.coordinate(&j.camera, dx, dy);
                        break :blk exact.sample(j.limit, &j.cancel) orelse return;
                    };
                    if (j.gpu_values) |values| values[index] = if (sample.escaped) @floatCast(sample.smooth) else -1;
                    if (!sample.escaped) unresolved += 1;
                    const color: [4]u8 = if (sample.escaped) j.colors[@as(usize, @intFromFloat(@mod(sample.smooth * 0.026, 1.0) * 4096)) & 4095] else .{ 17, 12, 9, 255 };
                    @memcpy(j.pixels[index * 4 ..][0..4], &color);
                }
                _ = j.rows.fetchAdd(1, .release);
            }
        }
    }
};
