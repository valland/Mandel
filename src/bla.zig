//! Non-overlapping BLA hierarchy, starting at reference iteration 1.
//! Each node carries an absolute remainder bound Q (|dz| + |dc|)^2.
//! Bounds compose using triangle inequalities; no escape steps are skipped.
const std = @import("std");
const Complex = @import("fractal.zig").Complex;
pub const Node = extern struct {
    a: [4]f32,
    b: [4]f32,
    radius: f32,
    quadratic: f32,
    gain: f32,
    steps: u32,
};
const Full = struct {
    a: Complex,
    b: Complex,
    radius: f64,
    quadratic: f64,
    steps: u32,
};
fn mul(a: Complex, b: Complex) Complex {
    return .{ .x = a.x * b.x - a.y * b.y, .y = a.x * b.y + a.y * b.x };
}
fn mag(a: Complex) f64 {
    return @sqrt(a.x * a.x + a.y * a.y);
}
fn split(x: f64) [2]f32 {
    const h: f32 = @floatCast(x);
    return .{ h, @floatCast(x - h) };
}
fn pack(z: Complex) [4]f32 {
    const x = split(z.x);
    const y = split(z.y);
    return .{ x[0], x[1], y[0], y[1] };
}
fn encode(n: Full) Node {
    if (!std.math.isFinite(n.quadratic) or n.quadratic > 1e30 or mag(n.a) > 1e30 or mag(n.b) > 1e30)
        return .{ .a = @splat(0), .b = @splat(0), .radius = 0, .quadratic = 0, .gain = 0, .steps = 0 };
    return .{ .a = pack(n.a), .b = pack(n.b), .radius = @floatCast(n.radius * (1 - 1e-6)), .quadratic = @floatCast(n.quadratic * (1 + 1e-6)), .gain = @floatCast(mag(n.a) * (1 + 1e-6)), .steps = n.steps };
}
pub const Table = struct {
    nodes: []Node,
    // Complete binary tree; leaves at `leaves`, reference r at leaves+r-1.
    leaves: u32,
    pub fn deinit(t: *Table) void {
        std.heap.page_allocator.free(t.nodes);
    }
    pub fn init(orbit: []const Complex, cmax: f64) !Table {
        const gpa = std.heap.page_allocator;
        var leaves: u32 = 1;
        while (leaves < orbit.len) leaves *= 2;
        const full = try gpa.alloc(Full, leaves * 2);
        defer gpa.free(full);
        const invalid: Full = .{ .a = .{ .x = 0, .y = 0 }, .b = .{ .x = 0, .y = 0 }, .radius = 0, .quadratic = 0, .steps = 0 };
        @memset(full, invalid);
        for (1..orbit.len) |r| {
            if (r + 1 >= orbit.len or mag(orbit[r]) > 8 or mag(orbit[r + 1]) > 8) continue;
            const z = orbit[r];
            full[leaves + r - 1] = .{ .a = .{ .x = 2 * z.x, .y = 2 * z.y }, .b = .{ .x = 1, .y = 0 }, .radius = mag(z) * 2e-13, .quadratic = 1, .steps = 1 };
        }
        var i = leaves - 1;
        while (i > 0) : (i -= 1) {
            const x = full[i * 2];
            const y = full[i * 2 + 1];
            if (x.steps == 0 or y.steps == 0 or x.radius == 0 or y.radius == 0) continue;
            const ax = mag(x.a);
            const bx = mag(x.b);
            var radius = x.radius;
            // Ensure every intermediate exact delta is within the next node's domain.
            var attempts: u32 = 0;
            while (ax * radius + bx * cmax + x.quadratic * (radius + cmax) * (radius + cmax) > y.radius and attempts < 80) : (attempts += 1) radius *= 0.5;
            if (attempts == 80) continue;
            const l = @max(ax, bx) + x.quadratic * (radius + cmax);
            const q = mag(y.a) * x.quadratic + y.quadratic * (l + 1) * (l + 1);
            const a = mul(y.a, x.a);
            var b = mul(y.a, x.b);
            b.x += y.b.x;
            b.y += y.b.y;
            full[i] = .{ .a = a, .b = b, .radius = radius, .quadratic = q, .steps = x.steps + y.steps };
        }
        const nodes = try gpa.alloc(Node, leaves * 2);
        for (full, nodes) |n, *out| out.* = encode(n);
        return .{ .nodes = nodes, .leaves = leaves };
    }
};
