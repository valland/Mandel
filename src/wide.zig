//! Double-double CPU refinement for pixels whose propagated FP64 error is
//! too large. Reference low parts come from MPFR, not a rounded FP64 orbit.
const std = @import("std");
const f = @import("fractal.zig");
const D = struct {
    h: f64,
    l: f64 = 0,
    fn add(a: D, b: D) D {
        const s = a.h + b.h;
        const v = s - a.h;
        const e = (a.h - (s - v)) + (b.h - v) + a.l + b.l;
        const h = s + e;
        return .{ .h = h, .l = e - (h - s) };
    }
    fn neg(a: D) D {
        return .{ .h = -a.h, .l = -a.l };
    }
    fn mul(a: D, b: D) D {
        const h = a.h * b.h;
        const l = @mulAdd(f64, a.h, b.h, -h) + a.h * b.l + a.l * b.h;
        const s = h + l;
        return .{ .h = s, .l = l - (s - h) };
    }
    fn shift(a: D, e: i32) D {
        return .{ .h = std.math.ldexp(a.h, e), .l = std.math.ldexp(a.l, e) };
    }
};
const C = struct {
    x: D,
    y: D,
    fn add(a: C, b: C) C {
        return .{ .x = a.x.add(b.x), .y = a.y.add(b.y) };
    }
    fn mul(a: C, b: C) C {
        return .{ .x = a.x.mul(b.x).add(a.y.mul(b.y).neg()), .y = a.x.mul(b.y).add(a.y.mul(b.x)) };
    }
    fn twice(a: C) C {
        return a.add(a);
    }
    fn norm(a: C) f64 {
        return a.x.h * a.x.h + a.y.h * a.y.h;
    }
};
pub fn sample(orbit: []const f.Complex, low: []const f.Complex, dx: f64, dy: f64, mantissa: f64, exponent: i32, limit: u32) ?f.Sample {
    if (exponent < -500) return null;
    const m: D = .{ .h = mantissa };
    const c: C = .{ .x = (D{ .h = dx }).mul(m).shift(exponent), .y = (D{ .h = dy }).mul(m).shift(exponent) };
    var w: C = .{ .x = .{ .h = 0 }, .y = .{ .h = 0 } };
    var r: usize = 0;
    var err: f64 = 0;
    for (0..limit) |i| {
        if (r + 1 >= orbit.len) return null;
        const z: C = .{ .x = .{ .h = orbit[r].x, .l = low[r].x }, .y = .{ .h = orbit[r].y, .l = low[r].y } };
        const wm = @sqrt(w.norm());
        const zm = @sqrt(z.norm());
        err = 2 * @sqrt(z.add(w).norm()) * err + err * err + 1e-30 * (2 * zm * wm + wm * wm + @sqrt(c.norm()));
        w = z.twice().add(w).mul(w).add(c);
        r += 1;
        const ref: C = .{ .x = .{ .h = orbit[r].x, .l = low[r].x }, .y = .{ .h = orbit[r].y, .l = low[r].y } };
        const total = ref.add(w);
        const norm = total.norm();
        if (!std.math.isFinite(norm) or err > 1e-10 * @max(1, @sqrt(norm))) return null;
        if (norm > 256) return f.escaped(@intCast(i + 1), norm);
        if (norm < 1e-24 * ref.norm()) return null;
        if (norm < w.norm() or r + 1 == orbit.len) {
            r = 0;
            w = total;
        }
    }
    return .{ .iterations = limit, .smooth = 0, .escaped = false };
}
