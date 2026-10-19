//! Rescaled perturbation and rebasing. Keep dz = (x + iy) * 2^exponent.
//! Reference: mathr, Deep zoom theory and practice (2021, 2022).
const std = @import("std");
const f = @import("fractal.zig");
pub fn sample(orbit: []const f.Complex, dx: f64, dy: f64, exponent: i32, limit: u32) ?f.Sample {
    if (exponent >= -500) return ordinary(orbit, std.math.ldexp(dx, exponent), std.math.ldexp(dy, exponent), limit);
    var x: f64 = 0;
    var y: f64 = 0;
    var e = exponent;
    var scale = std.math.ldexp(@as(f64, 1), e);
    var cx = dx;
    var cy = dy;
    var r: usize = 0;
    for (0..limit) |i| {
        if (r + 1 >= orbit.len) return null;
        const z = orbit[r];
        // Rare tiny reference iterates require full-range MPFR evaluation.
        if (r != 0 and @max(@abs(z.x), @abs(z.y)) < 1e-280) return null;
        const nx = 2 * (z.x * x - z.y * y) + scale * (x * x - y * y) + cx;
        y = 2 * (z.x * y + z.y * x) + scale * (2 * x * y) + cy;
        x = nx;
        r += 1;
        var magnitude = @max(@abs(x), @abs(y));
        if (!std.math.isFinite(magnitude)) return null;
        if (magnitude > 0 and (magnitude > 0x1p32 or magnitude < 0x1p-32)) {
            const shift = std.math.frexp(magnitude).exponent;
            x = std.math.ldexp(x, -shift);
            y = std.math.ldexp(y, -shift);
            e += shift;
            scale = std.math.ldexp(@as(f64, 1), e);
            cx = std.math.ldexp(dx, exponent - e);
            cy = std.math.ldexp(dy, exponent - e);
        }
        const zx = x * scale;
        const zy = y * scale;
        const ref = orbit[r];
        const ax = ref.x + zx;
        const ay = ref.y + zy;
        const norm = ax * ax + ay * ay;
        if (!std.math.isFinite(norm)) return null;
        if (norm > 256) return f.escaped(@intCast(i + 1), norm);
        if (norm < 1e-12 * (ref.x * ref.x + ref.y * ref.y)) return null;
        // Restart the reference, not the pixel's iteration count.
        if (norm < zx * zx + zy * zy or r + 1 == orbit.len) {
            r = 0;
            x = ax;
            y = ay;
            e = 0;
            scale = 1;
            cx = std.math.ldexp(dx, exponent);
            cy = std.math.ldexp(dy, exponent);
            magnitude = @max(@abs(x), @abs(y));
            if (magnitude > 0) {
                const shift = std.math.frexp(magnitude).exponent;
                x = std.math.ldexp(x, -shift);
                y = std.math.ldexp(y, -shift);
                e = shift;
                scale = std.math.ldexp(@as(f64, 1), e);
                cx = std.math.ldexp(dx, exponent - e);
                cy = std.math.ldexp(dy, exponent - e);
            }
        }
    }
    return .{ .iterations = limit, .smooth = 0, .escaped = false };
}
test "rescaled perturbation remains accurate beyond double exponent range" {
    const p = @import("precision.zig");
    for ([_]f64{ 38, 1100, 4000 }) |zoom| {
        var cam = p.Camera.init();
        defer cam.deinit();
        cam.preset(if (zoom == 38) 1 else 3);
        cam.zoom = zoom;
        cam.ensure();
        var exact = f.Exact.init(&cam);
        defer exact.deinit();
        const limit: u32 = @intFromFloat(zoom * 1.5 + 1600);
        const orbit = try std.testing.allocator.alloc(f.Complex, limit + 1);
        defer std.testing.allocator.free(orbit);
        var cancel = std.atomic.Value(bool).init(false);
        const n = f.reference(&exact, &cam, orbit, &cancel);
        var compared: usize = 0;
        for (0..19) |i| {
            const dx = (@as(f64, @floatFromInt(i)) - 9) / 19;
            const dy = dx * 0.43;
            exact.coordinate(&cam, dx, dy);
            const expected = exact.sample(limit, null).?;
            if (sample(orbit[0..n], dx * 3.4, -dy * 3.4, -@as(i32, @intFromFloat(zoom)), limit)) |actual| {
                compared += 1;
                try std.testing.expectEqual(expected.escaped, actual.escaped);
                try std.testing.expectEqual(expected.iterations, actual.iterations);
                if (expected.escaped) try std.testing.expectApproxEqAbs(expected.smooth, actual.smooth, 1e-5);
            }
        }
        try std.testing.expect(compared >= 16);
    }
}

// Ordinary FP64 exponent range: keep perturbations in physical coordinates,
// avoiding frexp/ldexp and dynamic exponent checks in every iteration.
fn ordinary(orbit: []const f.Complex, cx: f64, cy: f64, limit: u32) ?f.Sample {
    var x: f64 = 0;
    var y: f64 = 0;
    var r: usize = 0;
    var err: f64 = 0;
    for (0..limit) |i| {
        if (r + 1 >= orbit.len) return null;
        const z = orbit[r];
        const wm = @sqrt(x * x + y * y);
        const zm = @sqrt(z.x * z.x + z.y * z.y);
        const ax0 = z.x + x;
        const ay0 = z.y + y;
        err = 2 * @sqrt(ax0 * ax0 + ay0 * ay0) * err + err * err + 2e-15 * (2 * zm * wm + wm * wm + @sqrt(cx * cx + cy * cy));
        const nx = (2 * z.x + x) * x - (2 * z.y + y) * y + cx;
        y = 2 * (z.x * y + z.y * x + x * y) + cy;
        x = nx;
        r += 1;
        const ref = orbit[r];
        const ax = ref.x + x;
        const ay = ref.y + y;
        const norm = ax * ax + ay * ay;
        if (!std.math.isFinite(norm) or !std.math.isFinite(err)) return null;
        const total_error = err + 2e-15 * @sqrt(ref.x * ref.x + ref.y * ref.y);
        const radius = @sqrt(norm);
        if (norm > 256) {
            if (radius - total_error <= 16 or @log2(@log(radius + total_error) / @log(radius - total_error)) > 0.0001) return null;
            return f.escaped(@intCast(i + 1), norm);
        }
        if (radius + total_error >= 16 or total_error > 1) return null;
        if (norm < 1e-12 * (ref.x * ref.x + ref.y * ref.y)) return null;
        if (norm < x * x + y * y or r + 1 == orbit.len) {
            err = total_error + 2e-15 * radius;
            r = 0;
            x = ax;
            y = ay;
        }
    }
    return .{ .iterations = limit, .smooth = 0, .escaped = false };
}
