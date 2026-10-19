//! One immutable orbit reused for stationary-center zooms. A precision and
//! iteration reserve avoids rebuilding it at each zoom tick.
const std = @import("std");
const p = @import("precision.zig");
const f = @import("fractal.zig");
pub const Reference = struct {
    camera: p.Camera,
    orbit: []f.Complex,
    low: []f.Complex,
    count: usize,
    limit: u32,
    pub fn init(cam: *const p.Camera, limit: u32, cancel: *const std.atomic.Value(bool)) !Reference {
        var copy = cam.clone();
        errdefer copy.deinit();
        copy.bits += 256;
        copy.x.precision(copy.bits);
        copy.y.precision(copy.bits);
        const reserve = ((limit + 1023) / 1024) * 1024;
        const orbit = try std.heap.page_allocator.alloc(f.Complex, reserve + 1);
        errdefer std.heap.page_allocator.free(orbit);
        const low = try std.heap.page_allocator.alloc(f.Complex, reserve + 1);
        errdefer std.heap.page_allocator.free(low);
        var exact = f.Exact.init(&copy);
        defer exact.deinit();
        const n = f.referenceFull(&exact, &copy, orbit, low, cancel);
        return .{ .camera = copy, .orbit = orbit, .low = low, .count = n, .limit = reserve };
    }
    pub fn valid(ref: *const Reference, cam: *const p.Camera, limit: u32) bool {
        return ref.camera.bits >= cam.bits and ref.limit >= limit and p.c.mpfr_cmp(&ref.camera.x.v, &cam.x.v) == 0 and p.c.mpfr_cmp(&ref.camera.y.v, &cam.y.v) == 0;
    }
    pub fn deinit(ref: *Reference) void {
        ref.camera.deinit();
        std.heap.page_allocator.free(ref.orbit);
        std.heap.page_allocator.free(ref.low);
    }
};
