//! Versioned, atomic library storage. Coordinates are hexadecimal MPFR values.
const std = @import("std");
const p = @import("precision.zig");
const g = std.heap.page_allocator;
pub const Number = struct {
    digits: []const u8,
    exponent: i64,
    fn capture(a: std.mem.Allocator, value: *const p.Real) !Number {
        var exponent: c_long = 0;
        const raw = p.c.mpfr_get_str(null, &exponent, 16, 0, &value.v, p.round) orelse return error.OutOfMemory;
        defer p.c.mpfr_free_str(raw);
        return .{ .digits = try a.dupe(u8, std.mem.span(raw)), .exponent = exponent };
    }
    fn restore(n: Number, value: *p.Real) !void {
        const digits = if (std.mem.startsWith(u8, n.digits, "-")) n.digits[1..] else n.digits;
        if (digits.len == 0 or digits.len > 300000 or @abs(n.exponent) > 2000000) return error.InvalidCoordinate;
        for (digits) |ch| if (!std.ascii.isHex(ch)) return error.InvalidCoordinate;
        const z = try g.dupeSentinel(u8, n.digits, 0);
        defer g.free(z);
        if (p.c.mpfr_set_str(&value.v, z, 16, p.round) != 0) return error.InvalidCoordinate;
        _ = p.c.mpfr_mul_2si(&value.v, &value.v, 4 * (n.exponent - @as(i64, @intCast(digits.len))), p.round);
    }
};
pub const Record = struct {
    name: []const u8,
    comment: []const u8,
    saved_at: i64,
    zoom: f64,
    bits: u32,
    x: Number,
    y: Number,
    palette: usize,
    iterations: u32,
    width: u32,
    height: u32,
    thumbnail: []const u8,
    pub fn camera(r: Record) !p.Camera {
        if (!std.math.isFinite(r.zoom) or r.zoom < -2 or r.zoom > 1000000 or r.bits < 160 or r.bits > 1000200 or r.bits < @as(u32, @intFromFloat(@ceil(@max(0, r.zoom)) + 160)) or r.palette > 2 or r.iterations < 1 or r.iterations > 1000000) return error.InvalidRecord;
        var cam: p.Camera = .{ .x = p.Real.init(r.bits), .y = p.Real.init(r.bits), .zoom = r.zoom, .bits = r.bits };
        errdefer cam.deinit();
        try r.x.restore(&cam.x);
        try r.y.restore(&cam.y);
        return cam;
    }
};
const Document = struct { version: u32 = 1, places: []const Record };
pub const Store = struct {
    io: std.Io,
    path: []const u8,
    arena: std.heap.ArenaAllocator,
    records: std.ArrayList(Record) = .empty,
    thumbnails: std.ArrayList([]const u8) = .empty,
    pub fn init(io: std.Io, path: []const u8) !Store {
        var s: Store = .{ .io = io, .path = try g.dupe(u8, path), .arena = .init(g) };
        errdefer s.deinit();
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, g, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return s,
            else => return err,
        };
        defer g.free(bytes);
        const a = s.arena.allocator();
        const doc = try std.json.parseFromSliceLeaky(Document, a, bytes, .{ .allocate = .alloc_always });
        if (doc.version != 1) return error.UnsupportedVersion;
        for (doc.places) |r| {
            var cam = try r.camera();
            cam.deinit();
            if (r.name.len > 1024 or r.comment.len > 1024 or r.thumbnail.len > 1024 * 1024) return error.InvalidRecord;
            const png = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(r.thumbnail));
            try std.base64.standard.Decoder.decode(png, r.thumbnail);
            try s.records.append(g, r);
            try s.thumbnails.append(g, png);
        }
        return s;
    }
    pub fn deinit(s: *Store) void {
        s.records.deinit(g);
        s.thumbnails.deinit(g);
        s.arena.deinit();
        g.free(s.path);
    }
    pub fn add(s: *Store, cam: *const p.Camera, png: []const u8, name: []const u8, comment: []const u8, palette: usize, iterations: u32, width: u32, height: u32) !void {
        const a = s.arena.allocator();
        const encoded = try a.alloc(u8, std.base64.standard.Encoder.calcSize(png.len));
        _ = std.base64.standard.Encoder.encode(encoded, png);
        const record: Record = .{ .name = try a.dupe(u8, name), .comment = try a.dupe(u8, comment), .saved_at = std.Io.Clock.real.now(s.io).toSeconds(), .zoom = cam.zoom, .bits = cam.bits, .x = try Number.capture(a, &cam.x), .y = try Number.capture(a, &cam.y), .palette = palette, .iterations = iterations, .width = width, .height = height, .thumbnail = encoded };
        try s.records.append(g, record);
        errdefer _ = s.records.pop();
        try s.thumbnails.append(g, try a.dupe(u8, png));
        errdefer _ = s.thumbnails.pop();
        try s.write();
    }
    fn write(s: *Store) !void {
        const bytes = try std.json.Stringify.valueAlloc(g, Document{ .places = s.records.items }, .{});
        defer g.free(bytes);
        if (bytes.len > 64 * 1024 * 1024) return error.LibraryFull;
        if (std.fs.path.dirname(s.path)) |parent| try std.Io.Dir.cwd().createDirPath(s.io, parent);
        var file = try std.Io.Dir.cwd().createFileAtomic(s.io, s.path, .{ .replace = true });
        defer file.deinit(s.io);
        try file.file.writeStreamingAll(s.io, bytes);
        try file.file.sync(s.io);
        try file.replace(s.io);
    }
};
test "library survives reopen with exact deep coordinates, comments and thumbnail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buf);
    const path = try std.fmt.allocPrint(g, "{s}/places.json", .{buf[0..len]});
    defer g.free(path);
    var cam = p.Camera.init();
    defer cam.deinit();
    cam.zoom = 4000.125;
    cam.ensure();
    cam.pan(0.123, -0.456);
    {
        var store = try Store.init(std.testing.io, path);
        defer store.deinit();
        try store.add(&cam, "png data", "Deep edge", "En kommentar med æøå", 2, 32000, 1200, 800);
    }
    var store = try Store.init(std.testing.io, path);
    defer store.deinit();
    try std.testing.expectEqual(@as(usize, 1), store.records.items.len);
    const record = store.records.items[0];
    var restored = try record.camera();
    defer restored.deinit();
    try std.testing.expectEqual(cam.zoom, restored.zoom);
    try std.testing.expectEqual(@as(c_int, 0), p.c.mpfr_cmp(&cam.x.v, &restored.x.v));
    try std.testing.expectEqual(@as(c_int, 0), p.c.mpfr_cmp(&cam.y.v, &restored.y.v));
    try std.testing.expectEqualStrings("En kommentar med æøå", record.comment);
    try std.testing.expectEqualStrings("png data", store.thumbnails.items[0]);
}

test "failed writes roll back and corrupt libraries cannot be opened for saving" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buf);
    const path = try std.fmt.allocPrint(g, "{s}/places.json", .{buf[0..len]});
    defer g.free(path);
    var store = try Store.init(std.testing.io, path);
    defer store.deinit();
    try tmp.dir.createDir(std.testing.io, "places.json", .default_dir);
    var cam = p.Camera.init();
    defer cam.deinit();
    if (store.add(&cam, "png", "Fail", "", 0, 200, 20, 20)) |_| return error.ExpectedWriteFailure else |_| {}
    try std.testing.expectEqual(@as(usize, 0), store.records.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.thumbnails.items.len);
    try tmp.dir.deleteDir(std.testing.io, "places.json");
    var file = try tmp.dir.createFile(std.testing.io, "places.json", .{});
    try file.writeStreamingAll(std.testing.io, "invalid json");
    file.close(std.testing.io);
    if (Store.init(std.testing.io, path)) |opened| {
        var unexpected = opened;
        unexpected.deinit();
        return error.ExpectedReadFailure;
    } else |_| {}
    const contents = try tmp.dir.readFileAlloc(std.testing.io, "places.json", g, .limited(100));
    defer g.free(contents);
    try std.testing.expectEqualStrings("invalid json", contents);
}
