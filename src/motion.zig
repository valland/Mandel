//! Motion is bounded by actual source-pixel coverage, never a fixed allowance.
const std = @import("std");
pub const Motion = struct {
    velocity: f64 = 0,
    pub fn step(m: *Motion, zoom: f64, coverage_limit: f64, requested: f64, dt_in: f64) f64 {
        const dt = std.math.clamp(dt_in, 0, 0.05);
        const direction: f64 = if (requested < 0) -1 else 1;
        const headroom = @max(0, (coverage_limit - zoom) * direction);
        const target = @min(@abs(requested), headroom * 4);
        m.velocity += (target - m.velocity) * (1 - @exp(-dt * 8));
        return zoom + direction * @min(m.velocity * dt, headroom * (1 - @exp(-dt * 6)));
    }
};
test "delayed renders never consume the reserved native pixel density" {
    var motion: Motion = .{ .velocity = 2 };
    var zoom: f64 = 16;
    const limit = zoom + @log2(1.7 / 1.15);
    for (0..600) |_| {
        const next = motion.step(zoom, limit, 2, 1.0 / 120.0);
        try std.testing.expect(next >= zoom and next <= limit);
        try std.testing.expect(1.7 / std.math.exp2(next - 16) >= 1.15 - 1e-12);
        zoom = next;
    }
}

test "outbound motion never crosses the rendered spatial coverage" {
    var motion: Motion = .{};
    var zoom: f64 = 16;
    for (0..600) |_| {
        const next = motion.step(zoom, 15.65, -2, 1.0 / 120.0);
        try std.testing.expect(next <= zoom and next >= 15.65);
        zoom = next;
    }
    try std.testing.expect(zoom < 15.66);
}
