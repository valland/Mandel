//! Owned MPFR values. Camera precision grows with the pixel spacing.
const std = @import("std");
pub const c = @import("mpfr.zig");
pub const round = c.MPFR_RNDN;
pub const Real = struct {
    v: c.mpfr_t,
    pub fn init(bits: u32) Real {
        var r: Real = undefined;
        c.mpfr_init2(&r.v, bits);
        c.mpfr_set_zero(&r.v, 1);
        return r;
    }
    pub fn deinit(r: *Real) void {
        c.mpfr_clear(&r.v);
    }
    pub fn set(r: *Real, x: *const Real) void {
        _ = c.mpfr_set(&r.v, &x.v, round);
    }
    pub fn number(r: *Real, x: f64) void {
        _ = c.mpfr_set_d(&r.v, x, round);
    }
    pub fn decimal(r: *Real, x: [:0]const u8) void {
        std.debug.assert(c.mpfr_set_str(&r.v, x, 10, round) == 0);
    }
    pub fn double(r: *const Real) f64 {
        return c.mpfr_get_d(&r.v, round);
    }
    pub fn precision(r: *Real, bits: u32) void {
        _ = c.mpfr_prec_round(&r.v, bits, round);
    }
};
pub const Camera = struct {
    x: Real,
    y: Real,
    zoom: f64 = 0,
    bits: u32 = 160,
    pub fn init() Camera {
        var cam: Camera = .{ .x = Real.init(160), .y = Real.init(160) };
        cam.x.number(-0.5);
        return cam;
    }
    pub fn deinit(cam: *Camera) void {
        cam.x.deinit();
        cam.y.deinit();
    }
    pub fn clone(cam: *const Camera) Camera {
        var copy: Camera = .{ .x = Real.init(cam.bits), .y = Real.init(cam.bits), .zoom = cam.zoom, .bits = cam.bits };
        copy.x.set(&cam.x);
        copy.y.set(&cam.y);
        return copy;
    }
    pub fn ensure(cam: *Camera) void {
        const needed: u32 = @intFromFloat(@ceil(@max(0, cam.zoom)) + 160);
        if (needed > cam.bits) {
            cam.bits = needed;
            cam.x.precision(needed);
            cam.y.precision(needed);
        }
    }
    pub fn span(cam: *const Camera, out: *Real) void {
        const whole: c_long = @intFromFloat(@floor(cam.zoom));
        out.number(3.4 * std.math.exp2(-(cam.zoom - @floor(cam.zoom))));
        _ = c.mpfr_mul_2si(&out.v, &out.v, -whole, round);
    }
    // Offset in fractions of the viewport width; y is positive down.
    pub fn pan(cam: *Camera, dx: f64, dy: f64) void {
        cam.ensure();
        var s = Real.init(cam.bits);
        defer s.deinit();
        var t = Real.init(cam.bits);
        defer t.deinit();
        cam.span(&s);
        _ = c.mpfr_mul_d(&t.v, &s.v, dx, round);
        _ = c.mpfr_add(&cam.x.v, &cam.x.v, &t.v, round);
        _ = c.mpfr_mul_d(&t.v, &s.v, dy, round);
        _ = c.mpfr_sub(&cam.y.v, &cam.y.v, &t.v, round);
    }
    pub fn zoomAt(cam: *Camera, amount: f64, px: f64, py: f64) void {
        cam.pan(px, py);
        cam.zoom = @max(-2, cam.zoom + amount);
        cam.ensure();
        cam.pan(-px, -py);
    }
    pub fn preset(cam: *Camera, index: usize) void {
        cam.zoom = 0;
        switch (index) {
            1 => {
                cam.x.decimal("-0.743643887037151");
                cam.y.decimal("0.131825904205330");
                cam.zoom = 16;
            },
            2 => {
                cam.x.decimal("-0.10109636384562");
                cam.y.decimal("0.95628651080914");
                cam.zoom = 8;
            },
            // Exact boundary point, remains meaningful as precision grows.
            3 => {
                cam.x.number(-2);
                cam.y.number(0);
                cam.zoom = 4;
            },
            else => {
                cam.x.number(-0.5);
                cam.y.number(0);
            },
        }
        cam.ensure();
    }
};
test "camera retains sub-double offsets and cursor anchor" {
    var cam = Camera.init();
    defer cam.deinit();
    cam.zoom = 1100;
    cam.ensure();
    var old = cam.clone();
    defer old.deinit();
    cam.pan(0.25, 0);
    try std.testing.expect(c.mpfr_cmp(&cam.x.v, &old.x.v) != 0);
    cam.pan(-0.25, 0);
    try std.testing.expectEqual(@as(c_int, 0), c.mpfr_cmp(&cam.x.v, &old.x.v));
    cam.zoom = 12;
    cam.zoomAt(2, 0.2, -0.1);
    cam.zoomAt(-2, 0.2, -0.1);
    var delta = Real.init(cam.bits);
    defer delta.deinit();
    _ = c.mpfr_sub(&delta.v, &cam.x.v, &old.x.v, round);
    try std.testing.expect(@abs(delta.double()) < 1e-40);
}
