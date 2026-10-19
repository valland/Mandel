//! Dedicated full-resolution raw image surface; no thumbnail decoding.
const std = @import("std");
const ui = @import("nanoui").ui;
pub const key: u64 = 0x4d414e44454c;
pub fn keyFor(slot: u32) u64 {
    return key + slot;
}
pub fn upload(ctx: *ui.Context, pixels: []const u8, width: u32, height: u32) !void {
    return uploadSlot(ctx, pixels, width, height, 0);
}
pub fn uploadSlot(ctx: *ui.Context, pixels: []const u8, width: u32, height: u32, slot: u32) !void {
    const im = &ctx.text.images;
    const side = @max(width, height);
    const k = keyFor(slot);
    const old = im.decoded.get(k);
    const reusable = if (old) |maybe| if (maybe) |d| d.bgra.len == pixels.len else false else false;
    const copy = if (reusable) old.?.?.bgra else try im.gpa.alloc(u8, pixels.len);
    if (copy.ptr != pixels.ptr) @memcpy(copy, pixels);
    im.decoded.put(im.gpa, k, .{ .width = width, .height = height, .w = width, .h = height, .bgra = copy }) catch |err| {
        if (!reusable) im.gpa.free(copy);
        return err;
    };
    if (!reusable) {
        if (old) |maybe| if (maybe) |d| {
            im.kept_bytes -= d.bgra.len;
            im.gpa.free(d.bgra);
        };
        im.kept_bytes += copy.len;
    }
    im.raw_side = side;
    im.entries.clearRetainingCapacity();
    const sf: f32 = @floatFromInt(side);
    try im.entries.put(im.gpa, k, .{ .width = width, .height = height, .uv = .{ 0, 0, @as(f32, @floatFromInt(width)) / sf, @as(f32, @floatFromInt(height)) / sf } });
    if (im.sink) |sink| {
        sink.upload(sink.ctx, 0, 0, width, height, copy);
    } else {
        const bytes = @as(usize, side) * side * 4;
        if (im.pixels.len != bytes) {
            const replacement = try im.gpa.alloc(u8, bytes);
            @memset(replacement, 0);
            im.gpa.free(im.pixels);
            im.pixels = replacement;
        }
        for (0..height) |row| @memcpy(im.pixels[row * side * 4 ..][0 .. width * 4], copy[row * width * 4 ..][0 .. width * 4]);
    }
    im.generation +%= 1;
    im.dirty = .{ 0, side };
}

pub fn drawSlot(ctx: *ui.Context, width: f32, height: f32, factor: f32, offset: ui.Point, slot: u32, opacity: f32) void {
    _ = ctx.leaf(.{ .absolute = true, .offset = offset, .width = .{ .px = width * factor }, .height = .{ .px = height * factor } }, .{ .image = .{ .key = keyFor(slot), .bytes = "", .opacity = opacity } }, if (slot == 0) "fractal-a" else "fractal-b");
}

// Put dynamic uploads on the same queue as UI draws: an earlier frame must
// finish reading the old atlas region before a later image overwrites it.
// No waitUntilCompleted on the UI thread, and no unsynchronized CPU writes
// into a texture that a frame in flight might still be sampling.
pub fn queuedUpload(renderer: anytype, x: u32, y: u32, w: u32, h: u32, pixels: []const u8) void {
    const objc = @import("nanoui").objc;
    const side: usize = @max(w, h);
    if (renderer.images_texture) |t| {
        if (objc.msg(usize, t, "width", .{}) != side) {
            objc.release(t);
            renderer.images_texture = null;
        }
    }
    if (renderer.images_texture == null) {
        const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ @as(usize, 80), side, side, objc.NO });
        renderer.images_texture = objc.msg(objc.Object, renderer.device, "newTextureWithDescriptor:", .{desc});
    }
    const pitch = std.mem.alignForward(usize, @as(usize, w) * 4, 256);
    const buffer = objc.msg(?objc.Object, renderer.device, "newBufferWithLength:options:", .{ pitch * h, @as(usize, 0) }) orelse return;
    defer objc.release(buffer);
    const memory: [*]u8 = @ptrCast(objc.msg(*anyopaque, buffer, "contents", .{}));
    for (0..h) |row| @memcpy(memory[row * pitch ..][0 .. w * 4], pixels[row * w * 4 ..][0 .. w * 4]);
    const command = objc.msg(?objc.Object, renderer.queue, "commandBuffer", .{}) orelse return;
    const encoder = objc.msg(?objc.Object, command, "blitCommandEncoder", .{}) orelse return;
    const Size = extern struct { x: usize, y: usize, z: usize };
    objc.msg(void, encoder, "copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:", .{
        buffer, @as(usize, 0), pitch, pitch * h, Size{ .x = w, .y = h, .z = 1 }, renderer.images_texture.?, @as(usize, 0), @as(usize, 0), Size{ .x = x, .y = y, .z = 0 },
    });
    objc.msg(void, encoder, "endEncoding", .{});
    objc.msg(void, command, "commit", .{});
}

test "queued texture replacement is visible to the following Metal draw" {
    const View = struct {
        fn view(_: *@This(), ctx: *ui.Context) void {
            ui.column(ctx, .{ .width = .fill, .height = .fill });
            defer ui.end(ctx);
            drawSlot(ctx, 64, 64, 1, .{}, 0, 1);
        }
    };
    var state: View = .{};
    var tester: ui.Tester = undefined;
    try tester.init(std.testing.allocator, .init(&state, View.view), .{ .width = 64, .height = 64, .scale = 1 });
    defer tester.deinit();
    var pixels: [16 * 16 * 4]u8 = undefined;
    for (0..256) |i| @memcpy(pixels[i * 4 ..][0..4], &[_]u8{ 0, 0, 255, 255 });
    try upload(&tester.ctx, &pixels, 16, 16);
    tester.frame();
    const first = try tester.render(std.testing.allocator);
    first.deinit(std.testing.allocator);
    const Renderer = @TypeOf(tester.renderer);
    const Sink = struct {
        fn update(ptr: *anyopaque, x: u32, y: u32, w: u32, h: u32, bytes: []const u8) void {
            const renderer: *Renderer = @ptrCast(@alignCast(ptr));
            queuedUpload(renderer, x, y, w, h, bytes);
        }
    };
    tester.text.images.gpa.free(tester.text.images.pixels);
    tester.text.images.pixels = &.{};
    tester.text.images.sink = .{ .ctx = &tester.renderer, .upload = Sink.update };
    for (0..256) |i| @memcpy(pixels[i * 4 ..][0..4], &[_]u8{ 0, 255, 0, 255 });
    try upload(&tester.ctx, &pixels, 16, 16);
    tester.frame();
    const result = try tester.render(std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, result.bytes[(32 * 64 + 32) * 4 ..][0..4]);
}

test "Retina raw surface preserves alternating physical pixels beyond atlas size" {
    const View = struct {
        fn view(_: *@This(), ctx: *ui.Context) void {
            ui.column(ctx, .{ .width = .fill, .height = .fill });
            defer ui.end(ctx);
            drawSlot(ctx, ctx.size.w, ctx.size.h, 1, .{}, 0, 1);
        }
    };
    var state: View = .{};
    var tester: ui.Tester = undefined;
    try tester.init(std.testing.allocator, .init(&state, View.view), .{ .width = 1152, .height = 16, .scale = 2 });
    defer tester.deinit();
    const pixels = try std.testing.allocator.alloc(u8, 2304 * 32 * 4);
    defer std.testing.allocator.free(pixels);
    for (0..2304 * 32) |i| {
        const v: u8 = if (i % 2 == 0) 0 else 255;
        @memcpy(pixels[i * 4 ..][0..4], &[_]u8{ v, v, v, 255 });
    }
    try upload(&tester.ctx, pixels, 2304, 32);
    tester.frame();
    const rendered = try tester.render(std.testing.allocator);
    defer rendered.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2304), rendered.width);
    // Any downsampling, image-atlas cap, or subpixel shift destroys this pattern.
    try std.testing.expectEqualSlices(u8, pixels[2304 * 16 * 4 ..][0 .. 2304 * 4], rendered.bytes[2304 * 16 * 4 ..][0 .. 2304 * 4]);
}
