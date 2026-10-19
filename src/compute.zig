//! Metal compute backend; owned and used only by the background coordinator.
//! The UI never waits for a compute command buffer.
const std = @import("std");
const objc = @import("nanoui").objc;
const f = @import("fractal.zig");
const p = @import("precision.zig");
extern "c" fn MTLCreateSystemDefaultDevice() ?objc.Object;
const Size = extern struct { w: usize, h: usize, d: usize };
const Params = extern struct {
    width: u32,
    height: u32,
    limit: u32,
    count: u32,
    center: [4]f32,
    mantissa: [2]f32,
    exponent: i32,
    shallow: u32,
    palette: u32,
    first_row: u32,
    row_count: u32,
    padding: u32 = 0,
    coefficient: [4]f32,
    coefficient_exponent: i32,
    start: u32,
    leaves: u32,
    reserved: u32 = 0,
};
pub const Buffer = struct {
    object: ?objc.Object = null,
    capacity: usize = 0,
    fn deinit(b: *Buffer) void {
        if (b.object) |o| objc.release(o);
        b.* = .{};
    }
    fn reserve(b: *Buffer, device: objc.Object, bytes: usize) !void {
        if (b.capacity >= bytes) return;
        const capacity = @max(bytes, 4096);
        const object = objc.msg(?objc.Object, device, "newBufferWithLength:options:", .{ capacity, @as(usize, 0) }) orelse return error.GPUAllocation;
        b.deinit();
        b.* = .{ .object = object, .capacity = capacity };
    }
    fn slice(b: *Buffer, comptime T: type, count: usize) []T {
        const ptr: [*]T = @ptrCast(@alignCast(objc.msg(*anyopaque, b.object.?, "contents", .{})));
        return ptr[0..count];
    }
};
pub const GPU = struct {
    device: objc.Object,
    queue: objc.Object,
    pipeline: objc.Object,
    orbit: Buffer = .{},
    samples: Buffer = .{},
    pixels: Buffer = .{},
    palette: Buffer = .{},
    bla: Buffer = .{},
    stats: Buffer = .{},
    use_bla: bool = true,
    reuse: ?*const @import("reuse.zig").Cache = null,
    last_reused: usize = 0,
    last_skipped: u32 = 0,
    reference_id: u64 = std.math.maxInt(u64),
    palette_id: usize = 99,
    pub fn init() !GPU {
        const pool = objc.Pool.push();
        defer pool.pop();
        const device = MTLCreateSystemDefaultDevice() orelse return error.NoMetalDevice;
        errdefer objc.release(device);
        const queue = objc.msg(?objc.Object, device, "newCommandQueue", .{}) orelse return error.GPUQueue;
        errdefer objc.release(queue);
        const options = objc.new("MTLCompileOptions");
        defer objc.release(options);
        objc.msg(void, options, "setFastMathEnabled:", .{false});
        var err: ?objc.Object = null;
        const library = objc.msg(?objc.Object, device, "newLibraryWithSource:options:error:", .{ objc.nsString(@embedFile("compute.metal")), options, &err }) orelse {
            if (err) |e| std.log.err("Metal shader: {s}", .{objc.fromNSString(objc.msg(objc.Object, e, "localizedDescription", .{}))});
            return error.ShaderCompile;
        };
        defer objc.release(library);
        const function = objc.msg(?objc.Object, library, "newFunctionWithName:", .{objc.nsString("mandel")}) orelse return error.GPUFunction;
        defer objc.release(function);
        const pipeline = objc.msg(?objc.Object, device, "newComputePipelineStateWithFunction:error:", .{ function, &err }) orelse return error.GPUPipeline;
        return .{ .device = device, .queue = queue, .pipeline = pipeline };
    }
    pub fn deinit(g: *GPU) void {
        g.orbit.deinit();
        g.samples.deinit();
        g.pixels.deinit();
        g.palette.deinit();
        g.bla.deinit();
        g.stats.deinit();
        objc.release(g.pipeline);
        objc.release(g.queue);
        objc.release(g.device);
    }
    pub fn run(g: *GPU, cam: *const p.Camera, orbit: []const f.Complex, reference_id: u64, width: u32, height: u32, limit: u32, palette: usize, cancel: *const std.atomic.Value(bool), rows: *std.atomic.Value(u32)) !void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const count: usize = @as(usize, width) * height;
        try g.orbit.reserve(g.device, @max(1, orbit.len) * 16);
        try g.samples.reserve(g.device, count * 4);
        try g.pixels.reserve(g.device, count * 4);
        try g.palette.reserve(g.device, 4096 * 4);
        try g.stats.reserve(g.device, 4);
        if (g.reference_id != reference_id) {
            for (orbit, g.orbit.slice([4]f32, orbit.len)) |z, *out| out.* = pack(z.x, z.y);
            g.reference_id = reference_id;
        }
        if (g.palette_id != palette) {
            for (g.palette.slice([4]u8, 4096), 0..) |*out, i| out.* = f.color(.{ .iterations = 0, .escaped = true, .smooth = @as(f64, @floatFromInt(i)) / (4096 * 0.026) }, palette);
            g.palette_id = palette;
        }
        g.stats.slice(u32, 1)[0] = 0;
        const reuse_direction = if (g.reuse) |cache| cache.direction(cam, width, height, limit, palette) else 0;
        g.last_reused = if (reuse_direction != 0) g.reuse.?.seed(reuse_direction, g.pixels.slice(u8, count * 4), g.samples.slice(f32, count)) else 0;
        const whole: i32 = @intFromFloat(@floor(cam.zoom));
        const mantissa = 3.4 * std.math.exp2(-(cam.zoom - @floor(cam.zoom)));
        const aspect = @as(f64, @floatFromInt(height)) / @as(f64, @floatFromInt(width));
        const prefix = @import("prefix.zig").build(orbit, -whole, mantissa, @sqrt(0.25 + 0.25 * aspect * aspect) * 1.001, limit);
        const radius = @sqrt(0.25 + 0.25 * aspect * aspect) * 1.001;
        var table = try @import("bla.zig").Table.init(if (cam.zoom >= 40 and cam.zoom <= 100) orbit else orbit[0..@min(2, orbit.len)], std.math.ldexp(mantissa * radius, -whole));
        defer table.deinit();
        try g.bla.reserve(g.device, table.nodes.len * @sizeOf(@import("bla.zig").Node));
        @memcpy(g.bla.slice(@import("bla.zig").Node, table.nodes.len), table.nodes);
        var params: Params = .{ .width = width, .height = height, .limit = limit, .count = @intCast(orbit.len), .center = pack(cam.x.double(), cam.y.double()), .mantissa = split(3.4 * std.math.exp2(-(cam.zoom - @floor(cam.zoom)))), .exponent = -whole, .shallow = if (cam.zoom < 8) 1 else if (cam.zoom <= 100) 2 else 0, .palette = @intCast(palette), .first_row = 0, .row_count = 0, .reserved = if (reuse_direction == 1) 1 else if (reuse_direction == -1) 2 else 0, .coefficient = pack(prefix.x, prefix.y), .coefficient_exponent = prefix.exponent, .start = prefix.steps, .leaves = if (g.use_bla and cam.zoom >= 40) table.leaves else 0 };
        // Two bounded batches in flight avoid a host wait after every dispatch,
        // while preserving cancellation and ordering before buffer reuse.
        var pending: [2]?objc.Object = .{ null, null };
        var completed_rows: [2]u32 = .{ 0, 0 };
        defer for (pending) |maybe| if (maybe) |cmd| objc.msg(void, cmd, "waitUntilCompleted", .{});
        var y: u32 = 0;
        var batch: usize = 0;
        while (y < height) : ({
            y += 128;
            batch += 1;
        }) {
            const slot = batch % pending.len;
            if (pending[slot]) |cmd| {
                objc.msg(void, cmd, "waitUntilCompleted", .{});
                if (objc.msg(usize, cmd, "status", .{}) != 4) return error.GPUExecution;
                rows.store(completed_rows[slot], .release);
                pending[slot] = null;
            }
            if (cancel.load(.acquire)) return error.Cancelled;
            params.first_row = y;
            params.row_count = @min(128, height - y);
            const command = objc.msg(?objc.Object, g.queue, "commandBuffer", .{}) orelse return error.GPUCommand;
            const encoder = objc.msg(?objc.Object, command, "computeCommandEncoder", .{}) orelse return error.GPUEncoder;
            objc.msg(void, encoder, "setComputePipelineState:", .{g.pipeline});
            objc.msg(void, encoder, "setBytes:length:atIndex:", .{ @as(*const anyopaque, &params), @as(usize, @sizeOf(Params)), @as(usize, 0) });
            for ([_]objc.Object{ g.orbit.object.?, g.samples.object.?, g.pixels.object.?, g.palette.object.?, g.bla.object.?, g.stats.object.? }, 1..) |buffer, index| objc.msg(void, encoder, "setBuffer:offset:atIndex:", .{ buffer, @as(usize, 0), index });
            const dispatch_width = if (reuse_direction == 1) ((width + 1) / 2) * 3 else width;
            const dispatch_height = if (reuse_direction == 1) (params.row_count + 1) / 2 else params.row_count;
            objc.msg(void, encoder, "dispatchThreadgroups:threadsPerThreadgroup:", .{ Size{ .w = (dispatch_width + 15) / 16, .h = (dispatch_height + 7) / 8, .d = 1 }, Size{ .w = 16, .h = 8, .d = 1 } });
            objc.msg(void, encoder, "endEncoding", .{});
            objc.msg(void, command, "commit", .{});
            pending[slot] = command;
            completed_rows[slot] = y + params.row_count;
        }
        for (&pending) |*maybe| if (maybe.*) |cmd| {
            objc.msg(void, cmd, "waitUntilCompleted", .{});
            if (objc.msg(usize, cmd, "status", .{}) != 4) return error.GPUExecution;
            maybe.* = null;
        };
        rows.store(height, .release);
        g.last_skipped = g.stats.slice(u32, 1)[0];
    }
    pub fn values(g: *GPU, count: usize) []f32 {
        return g.samples.slice(f32, count);
    }
    pub fn bytes(g: *GPU, count: usize) []const u8 {
        return g.pixels.slice(u8, count * 4);
    }
};
fn split(value: f64) [2]f32 {
    const hi: f32 = @floatCast(value);
    return .{ hi, @floatCast(value - @as(f64, hi)) };
}
fn pack(x: f64, y: f64) [4]f32 {
    const a = split(x);
    const b = split(y);
    return .{ a[0], a[1], b[0], b[1] };
}
