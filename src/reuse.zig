//! Exact temporal reuse on centered odd-sized grids, one octave apart.
//! No interpolation, color similarity tests, or approximate coordinates.
const std = @import("std");
const p = @import("precision.zig");
const g = std.heap.page_allocator;
pub const Cache = struct {
    camera: ?p.Camera = null,
    pixels: []u8 = &.{},
    samples: []f32 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    limit: u32 = 0,
    palette: usize = 0,
    pub fn deinit(c: *Cache) void {
        if (c.camera) |*cam| cam.deinit();
        g.free(c.pixels);
        g.free(c.samples);
        c.* = .{};
    }
    pub fn direction(c: *const Cache, cam: *const p.Camera, w: u32, h: u32, limit: u32, palette: usize) i32 {
        const old = c.camera orelse return 0;
        if (w != c.width or h != c.height or w % 2 == 0 or h % 2 == 0 or limit != c.limit or palette != c.palette) return 0;
        if (p.c.mpfr_cmp(&old.x.v, &cam.x.v) != 0 or p.c.mpfr_cmp(&old.y.v, &cam.y.v) != 0) return 0;
        const delta = cam.zoom - old.zoom;
        return if (delta == 1) 1 else if (delta == -1) -1 else 0;
    }
    pub fn save(c: *Cache, cam: *const p.Camera, w: u32, h: u32, limit: u32, palette: usize, pixels: []const u8, samples: []const f32) !void {
        if (c.pixels.len != pixels.len) {
            c.deinit();
            c.pixels = try g.alloc(u8, pixels.len);
            errdefer c.deinit();
            c.samples = try g.alloc(f32, samples.len);
        }
        @memcpy(c.pixels, pixels);
        @memcpy(c.samples, samples);
        if (c.camera) |*old| old.deinit();
        c.camera = cam.clone();
        c.width = w;
        c.height = h;
        c.limit = limit;
        c.palette = palette;
    }
    pub fn seed(c: *const Cache, direction_: i32, pixels: []u8, samples: []f32) usize {
        @memset(samples, -2);
        var reused: usize = 0;
        for (0..c.height) |y| for (0..c.width) |x| {
            const source = sourceIndex(c.width, c.height, @intCast(x), @intCast(y), direction_) orelse continue;
            if (c.samples[source] == -2) continue;
            const dest = y * c.width + x;
            @memcpy(pixels[dest * 4 ..][0..4], c.pixels[source * 4 ..][0..4]);
            samples[dest] = c.samples[source];
            reused += 1;
        };
        return reused;
    }
};
pub fn sourceIndex(w: u32, h: u32, x: u32, y: u32, direction: i32) ?usize {
    const cx: i64 = @intCast(w / 2);
    const cy: i64 = @intCast(h / 2);
    var dx = @as(i64, x) - cx;
    var dy = @as(i64, y) - cy;
    if (direction == 1) {
        if (@mod(dx, 2) != 0 or @mod(dy, 2) != 0) return null;
        dx = @divExact(dx, 2);
        dy = @divExact(dy, 2);
    } else if (direction == -1) {
        dx *= 2;
        dy *= 2;
    } else return null;
    const sx = cx + dx;
    const sy = cy + dy;
    if (sx < 0 or sy < 0 or sx >= w or sy >= h) return null;
    return @intCast(sy * w + sx);
}
test "dyadic reused coordinates are identical in both directions" {
    for ([_]i32{ 1, -1 }) |direction| {
        var count: usize = 0;
        for (0..49) |y| for (0..65) |x| {
            if (sourceIndex(65, 49, @intCast(x), @intCast(y), direction)) |source| {
                const new_x = (@as(f64, @floatFromInt(x)) - 32) / 65 * std.math.exp2(-@as(f64, @floatFromInt(direction)));
                const old_x = (@as(f64, @floatFromInt(source % 65)) - 32) / 65;
                const new_y = (@as(f64, @floatFromInt(y)) - 24) / 65 * std.math.exp2(-@as(f64, @floatFromInt(direction)));
                const old_y = (@as(f64, @floatFromInt(source / 65)) - 24) / 65;
                try std.testing.expectEqual(new_x, old_x);
                try std.testing.expectEqual(new_y, old_y);
                count += 1;
            }
        };
        try std.testing.expectEqual(@as(usize, 33 * 25), count);
    }
}
