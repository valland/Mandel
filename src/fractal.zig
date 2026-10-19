const std = @import("std");
const p = @import("precision.zig");
const c = p.c;
const rnd = p.round;
const Real = p.Real;
pub const Complex = struct { x: f64, y: f64 };
pub const Sample = struct { iterations: u32, smooth: f64, escaped: bool };
pub fn escaped(n: u32, norm: f64) Sample {
    return .{ .iterations = n, .smooth = @as(f64, @floatFromInt(n)) + 1 - @log(@log(@sqrt(norm))) / @log(2.0), .escaped = true };
}
pub fn direct(x: f64, y: f64, limit: u32) Sample {
    var zx: f64 = 0;
    var zy: f64 = 0;
    for (0..limit) |i| {
        const nx = zx * zx - zy * zy + x;
        zy = 2 * zx * zy + y;
        zx = nx;
        const norm = zx * zx + zy * zy;
        if (norm > 256) return escaped(@intCast(i + 1), norm);
    }
    return .{ .iterations = limit, .smooth = 0, .escaped = false };
}
// Scratch values reused across pixels; no per-iteration allocations in Zig.
pub const Exact = struct {
    x: Real,
    y: Real,
    zx: Real,
    zy: Real,
    xx: Real,
    yy: Real,
    xy: Real,
    temp: Real,
    scale: Real,
    pub fn init(cam: *const p.Camera) Exact {
        var e: Exact = undefined;
        inline for (comptime std.meta.fieldNames(Exact)) |name| @field(e, name) = Real.init(cam.bits);
        cam.span(&e.scale);
        return e;
    }
    pub fn deinit(e: *Exact) void {
        inline for (comptime std.meta.fieldNames(Exact)) |name| @field(e, name).deinit();
    }
    pub fn coordinate(e: *Exact, cam: *const p.Camera, dx: f64, dy: f64) void {
        _ = c.mpfr_mul_d(&e.temp.v, &e.scale.v, dx, rnd);
        _ = c.mpfr_add(&e.x.v, &cam.x.v, &e.temp.v, rnd);
        _ = c.mpfr_mul_d(&e.temp.v, &e.scale.v, dy, rnd);
        _ = c.mpfr_sub(&e.y.v, &cam.y.v, &e.temp.v, rnd);
    }
    fn step(e: *Exact) f64 {
        _ = c.mpfr_sqr(&e.xx.v, &e.zx.v, rnd);
        _ = c.mpfr_sqr(&e.yy.v, &e.zy.v, rnd);
        _ = c.mpfr_mul(&e.xy.v, &e.zx.v, &e.zy.v, rnd);
        _ = c.mpfr_mul_2ui(&e.zy.v, &e.xy.v, 1, rnd);
        _ = c.mpfr_add(&e.zy.v, &e.zy.v, &e.y.v, rnd);
        _ = c.mpfr_sub(&e.zx.v, &e.xx.v, &e.yy.v, rnd);
        _ = c.mpfr_add(&e.zx.v, &e.zx.v, &e.x.v, rnd);
        const x = e.zx.double();
        const y = e.zy.double();
        return x * x + y * y;
    }
    pub fn sample(e: *Exact, limit: u32, cancel: ?*const std.atomic.Value(bool)) ?Sample {
        e.zx.number(0);
        e.zy.number(0);
        for (0..limit) |i| {
            if (i % 64 == 0) if (cancel) |flag| {
                if (flag.load(.acquire)) return null;
            };
            const norm = e.step();
            if (norm > 256) return escaped(@intCast(i + 1), norm);
        }
        return .{ .iterations = limit, .smooth = 0, .escaped = false };
    }
};
pub fn reference(e: *Exact, cam: *const p.Camera, orbit: []Complex, cancel: *const std.atomic.Value(bool)) usize {
    return referenceFull(e, cam, orbit, null, cancel);
}
pub fn referenceFull(e: *Exact, cam: *const p.Camera, orbit: []Complex, low: ?[]Complex, cancel: *const std.atomic.Value(bool)) usize {
    e.coordinate(cam, 0, 0);
    e.zx.number(0);
    e.zy.number(0);
    orbit[0] = .{ .x = 0, .y = 0 };
    if (low) |l| l[0] = .{ .x = 0, .y = 0 };
    for (orbit[1..], 1..) |*z, i| {
        if (cancel.load(.acquire)) return i;
        const norm = e.step();
        z.* = .{ .x = e.zx.double(), .y = e.zy.double() };
        if (low) |l| {
            e.xx.number(z.x);
            _ = c.mpfr_sub(&e.temp.v, &e.zx.v, &e.xx.v, rnd);
            l[i].x = e.temp.double();
            e.yy.number(z.y);
            _ = c.mpfr_sub(&e.temp.v, &e.zy.v, &e.yy.v, rnd);
            l[i].y = e.temp.double();
        }
        if (norm > 1e100) return i + 1;
    }
    return orbit.len;
}
// A null result requests direct MPFR evaluation: escaped reference,
// cancellation of nearly equal values, or a range/precision problem.
pub fn perturb(orbit: []const Complex, dx: f64, dy: f64, limit: u32) ?Sample {
    var x: f64 = 0;
    var y: f64 = 0;
    for (0..limit) |i| {
        if (i + 1 >= orbit.len) return null;
        const z = orbit[i];
        const nx = 2 * (z.x * x - z.y * y) + x * x - y * y + dx;
        y = 2 * (z.x * y + z.y * x) + 2 * x * y + dy;
        x = nx;
        const ref = orbit[i + 1];
        const ax = ref.x + x;
        const ay = ref.y + y;
        const norm = ax * ax + ay * ay;
        if (!std.math.isFinite(norm) or norm < 1e-6 * (ref.x * ref.x + ref.y * ref.y)) return null;
        if (norm > 256) return escaped(@intCast(i + 1), norm);
    }
    return .{ .iterations = limit, .smooth = 0, .escaped = false };
}
pub fn color(s: Sample, palette: usize) [4]u8 {
    if (!s.escaped) return .{ 17, 12, 9, 255 };
    const t = s.smooth * 0.026;
    const phase: [3]f64 = switch (palette) {
        1 => .{ 0.05, 0.15, 0.32 },
        2 => .{ 0.0, 0.0, 0.0 },
        else => .{ 0.02, 0.22, 0.42 },
    };
    var rgb: [3]u8 = undefined;
    for (0..3) |i| rgb[i] = @intFromFloat(255 * std.math.pow(f64, 0.5 + 0.5 * @cos(6.28318530718 * (t + phase[i])), 0.8));
    return .{ rgb[2], rgb[1], rgb[0], 255 };
}
test "known interior and exterior points" {
    try std.testing.expect(!direct(0, 0, 500).escaped);
    try std.testing.expect(!direct(-1, 0, 500).escaped);
    try std.testing.expect(direct(1, 1, 500).escaped);
    try std.testing.expect(direct(-2.1, 0, 500).escaped);
}
test "perturbation agrees with MPFR across a deep viewport" {
    var cam = p.Camera.init();
    defer cam.deinit();
    cam.preset(1);
    cam.zoom = 38;
    cam.ensure();
    var e = Exact.init(&cam);
    defer e.deinit();
    var orbit: [2001]Complex = undefined;
    var cancel = std.atomic.Value(bool).init(false);
    const n = reference(&e, &cam, &orbit, &cancel);
    var compared: usize = 0;
    for (0..17) |i| {
        const dx = (@as(f64, @floatFromInt(i)) - 8) / 19;
        const dy = dx * 0.7;
        e.coordinate(&cam, dx, dy);
        const exact = e.sample(2000, null).?;
        if (perturb(orbit[0..n], dx * e.scale.double(), -dy * e.scale.double(), 2000)) |fast| {
            compared += 1;
            try std.testing.expectEqual(exact.escaped, fast.escaped);
            try std.testing.expectEqual(exact.iterations, fast.iterations);
            if (exact.escaped) try std.testing.expectApproxEqAbs(exact.smooth, fast.smooth, 1e-5);
        }
    }
    try std.testing.expect(compared > 0);
}

test "MPFR resolves opposite sides of the boundary beyond double range" {
    var cam = p.Camera.init();
    defer cam.deinit();
    cam.preset(3);
    cam.zoom = 1100;
    cam.ensure();
    var e = Exact.init(&cam);
    defer e.deinit();
    e.coordinate(&cam, -0.25, 0);
    try std.testing.expect(e.sample(1800, null).?.escaped);
    e.coordinate(&cam, 0.25, 0);
    try std.testing.expect(!e.sample(1800, null).?.escaped);
}
