//! Skip the common initial linear segment once per image. Propagate an
//! absolute bound for omitted quadratic terms; stop before cancellation,
//! escape, or relative truncation error above 1e-13. Coefficients retain a
//! separate exponent, so this optimization works beyond FP64's range.
const std = @import("std");
const f = @import("fractal.zig");
pub const Prefix = struct { x: f64 = 0, y: f64 = 0, exponent: i32 = 0, steps: u32 = 0 };
pub fn build(orbit: []const f.Complex, base: i32, mantissa: f64, radius: f64, limit: u32) Prefix {
    if (orbit.len < 2 or limit < 2 or base > -16) return .{};
    var result: Prefix = .{};
    var ax: f64 = 1;
    var ay: f64 = 0;
    var ae: i32 = 0;
    var error_bound: f64 = 0;
    const cmax = mantissa * radius;
    var n: usize = 1;
    while (n < orbit.len and n < limit) : (n += 1) {
        const ref = orbit[n];
        const magnitude = @sqrt(ax * ax + ay * ay) * cmax;
        const scale = std.math.ldexp(@as(f64, 1), base + ae);
        const bound = (magnitude + error_bound) * scale;
        const refnorm = @sqrt(ref.x * ref.x + ref.y * ref.y);
        if (!std.math.isFinite(magnitude) or !std.math.isFinite(error_bound) or magnitude == 0 or
            error_bound > 1e-13 * magnitude or bound > 1e-4 or refnorm + bound > 8 or bound > refnorm * 1e-3) break;
        result = .{ .x = ax, .y = ay, .exponent = ae, .steps = @intCast(n) };
        error_bound = 2 * refnorm * error_bound + scale * (magnitude + error_bound) * (magnitude + error_bound);
        const nx = 2 * (ref.x * ax - ref.y * ay) + std.math.ldexp(@as(f64, 1), -ae);
        ay = 2 * (ref.x * ay + ref.y * ax);
        ax = nx;
        const m = @max(@abs(ax), @abs(ay));
        if (m > 0 and (m > 65536 or m < 1.0 / 65536.0)) {
            const k = std.math.frexp(m).exponent;
            ax = std.math.ldexp(ax, -k);
            ay = std.math.ldexp(ay, -k);
            error_bound = std.math.ldexp(error_bound, -k);
            ae += k;
        }
    }
    return result;
}
test "prefix skips hundreds of deep iterations with bounded error" {
    const p = @import("precision.zig");
    var cam = p.Camera.init();
    defer cam.deinit();
    cam.preset(3);
    cam.zoom = 4000;
    cam.ensure();
    var exact = f.Exact.init(&cam);
    defer exact.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    const orbit = try std.testing.allocator.alloc(f.Complex, 6201);
    defer std.testing.allocator.free(orbit);
    const n = f.reference(&exact, &cam, orbit, &cancel);
    const prefix = build(orbit[0..n], -4000, 3.4, 0.75, 6200);
    try std.testing.expect(prefix.steps > 1900 and prefix.steps < 2000);
}
