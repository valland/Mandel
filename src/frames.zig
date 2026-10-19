const std = @import("std");
const ui = @import("nanoui").ui;
const p = @import("precision.zig");
const Job = @import("worker.zig").Job;
const display = @import("display.zig");
pub const Frame = struct {
    camera: p.Camera,
    pixels: []u8,
    width: u32,
    height: u32,
    slot: u32,
    viewport: ui.Size,
    fn deinit(f: *Frame) void {
        f.camera.deinit();
        std.heap.page_allocator.free(f.pixels);
    }
    fn draw(f: *const Frame, ctx: *ui.Context, cam: *const p.Camera, rect: ui.Rect, opacity: f32) void {
        if (!ctx.text.images.decoded.contains(display.keyFor(f.slot))) display.uploadSlot(ctx, f.pixels, f.width, f.height, f.slot) catch return;
        const same_center = p.c.mpfr_cmp(&f.camera.x.v, &cam.x.v) == 0 and p.c.mpfr_cmp(&f.camera.y.v, &cam.y.v) == 0;
        const native_width = @as(f32, @floatFromInt(f.width)) / ctx.scale;
        const native_height = @as(f32, @floatFromInt(f.height)) / ctx.scale;
        // Hold old geometry on resize. It must not stretch with the new window.
        const desired: f32 = if (same_center) @floatCast(std.math.exp2(std.math.clamp(cam.zoom - f.camera.zoom, 0, 20))) else 1;
        const factor = @min(desired, @min(native_width / f.viewport.w, native_height / f.viewport.h));
        const width = f.viewport.w * factor;
        const height = f.viewport.h * factor;
        display.drawSlot(ctx, width, height, 1, .{ .x = (rect.w - width) * 0.5, .y = (rect.h - height) * 0.5 }, f.slot, opacity);
    }
};
pub const Frames = struct {
    base: ?Frame = null,
    ahead: ?Frame = null,
    pub fn clearAhead(fs: *Frames) void {
        if (fs.ahead) |*f| f.deinit();
        fs.ahead = null;
    }
    pub fn deinit(fs: *Frames) void {
        if (fs.base) |*f| f.deinit();
        fs.base = null;
        fs.clearAhead();
    }
    pub fn accept(fs: *Frames, ctx: *ui.Context, j: *Job, viewport: ui.Size, prefetch: bool) !void {
        if (!prefetch) try display.uploadSlot(ctx, j.pixels, j.width, j.height, 0);
        const frame: Frame = .{ .camera = j.camera.clone(), .pixels = j.pixels, .width = j.width, .height = j.height, .slot = 0, .viewport = viewport };
        j.pixels = &.{};
        fs.clearAhead();
        if (prefetch) {
            fs.ahead = frame;
            return;
        }
        if (fs.base) |*f| f.deinit();
        fs.base = frame;
    }
    pub fn coverageLimit(fs: *const Frames, scale: f32) ?f64 {
        const f = fs.base orelse return null;
        const density = @min(@as(f64, @floatFromInt(f.width)) / (f.viewport.w * scale), @as(f64, @floatFromInt(f.height)) / (f.viewport.h * scale));
        return f.camera.zoom + @log2(@max(1, density / 1.15));
    }
    pub fn promote(fs: *Frames, ctx: *ui.Context, zoom: f64) !void {
        const f = fs.ahead orelse return;
        if (fs.base) |base| {
            if (f.camera.zoom < base.camera.zoom) {
                // A wider frame is usable only once its center crop is native resolution.
                const density = @min(@as(f64, @floatFromInt(f.width)) / (f.viewport.w * ctx.scale), @as(f64, @floatFromInt(f.height)) / (f.viewport.h * ctx.scale));
                if (zoom > f.camera.zoom + @log2(@max(1, density / 1.15))) return;
            } else if (zoom < f.camera.zoom) return;
        }
        try display.uploadSlot(ctx, f.pixels, f.width, f.height, 0);
        if (fs.base) |*old| old.deinit();
        fs.base = f;
        fs.ahead = null;
    }
    pub fn draw(fs: *Frames, ctx: *ui.Context, cam: *const p.Camera, rect: ui.Rect) void {
        if (fs.base) |*f| f.draw(ctx, cam, rect, 1) else ui.text(ctx, "Finding the boundary...", .{ .size = 18, .color = .hex(0x7ee6d5) });
    }
};
