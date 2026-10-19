const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const p = @import("precision.zig");
const places = @import("places.zig");
const g = std.heap.page_allocator;
pub const Draft = struct {
    camera: p.Camera,
    png: []u8,
    palette: usize,
    iterations: u32,
    width: u32,
    height: u32,
    fn deinit(d: *Draft) void {
        d.camera.deinit();
        g.free(d.png);
    }
};
pub const Library = struct {
    store: ?places.Store = null,
    window: ?*nanoui.Window = null,
    draft: ?Draft = null,
    revision: u64 = 0,
    selected: ?usize = null,
    name: ui.TextBuffer = .{},
    comment: ui.TextBuffer = .{},
    message: ?[]const u8 = null,
    owner: ?*anyopaque = null,
    load: ?*const fn (*anyopaque, places.Record) void = null,
    pub fn deinit(l: *Library) void {
        if (l.draft) |*d| d.deinit();
        if (l.store) |*s| s.deinit();
    }
    pub fn capture(l: *Library, cam: *const p.Camera, pixels: []const u8, width: u32, height: u32, palette: usize, iterations: u32) !void {
        const factor = 384.0 / @as(f64, @floatFromInt(@max(width, height)));
        const w: u32 = @intFromFloat(@max(1, @round(@as(f64, @floatFromInt(width)) * factor)));
        const h: u32 = @intFromFloat(@max(1, @round(@as(f64, @floatFromInt(height)) * factor)));
        const small = try g.alloc(u8, w * h * 4);
        defer g.free(small);
        // Area averaging preserves thin boundaries in the small preview.
        for (0..h) |y| for (0..w) |x| {
            const x0 = x * width / w;
            const x1 = @min(width, @max(x0 + 1, (x + 1) * width / w));
            const y0 = y * height / h;
            const y1 = @min(height, @max(y0 + 1, (y + 1) * height / h));
            var sum: [4]u64 = .{ 0, 0, 0, 0 };
            for (y0..y1) |sy| for (x0..x1) |sx| {
                for (0..4) |ch| sum[ch] += pixels[(sy * width + sx) * 4 + ch];
            };
            for (0..4) |ch| small[(y * w + x) * 4 + ch] = @intCast(sum[ch] / ((x1 - x0) * (y1 - y0)));
        };
        const png = try ui.png.encode(g, .{ .bytes = small, .width = w, .height = h });
        if (l.draft) |*d| d.deinit();
        l.draft = .{ .camera = cam.clone(), .png = png, .palette = palette, .iterations = iterations, .width = width, .height = height };
        l.revision += 1;
        l.name.set("Untitled area");
        l.comment.clear();
        l.message = null;
    }
    pub fn open(l: *Library, parent: *nanoui.Window) !void {
        if (l.window) |win| {
            win.redraw();
            if (!parent.app.flags.hidden) win.focus();
            return;
        }
        l.window = try parent.app.newWindow(.{ .title = "Mandel — Saved areas", .width = 1000, .height = 760, .min_width = 700, .min_height = 520, .theme = theme(), .on_close = .{ .ctx = l, .func = closed }, .content = .{ .view = .init(l, view) } });
    }
    fn closed(ptr: *anyopaque, _: *nanoui.Window) void {
        const l: *Library = @ptrCast(@alignCast(ptr));
        l.window = null;
    }
    pub fn theme() ui.Theme {
        var t = ui.Theme.dark_theme;
        t.background = .hex(0x090d13);
        t.surface = .hex(0x182330);
        t.border = .hex(0x263343);
        t.accent = .hex(0x7ee6d5);
        t.accent_hover = .hex(0xa0f3e5);
        t.accent_text = .hex(0x0b2927);
        return t;
    }
    pub fn view(l: *Library, ctx: *ui.Context) void {
        // Keep a CPU-backed atlas even if AppKit installs a GPU sink after
        // attachment's first paint. Mixing paths erased new thumbnails.
        ctx.text.images.sink = null;
        ui.column(ctx, .{ .width = .fill, .height = .fill, .background = .hex(0x090d13), .padding = .all(24), .gap = 16 });
        defer ui.end(ctx);
        {
            ui.row(ctx, .{ .width = .fill, .align_items = .center, .gap = 14 });
            defer ui.end(ctx);
            ui.text(ctx, "M /", .{ .size = 27, .weight = .bold, .color = .hex(0x7ee6d5) });
            ui.column(ctx, .{ .gap = 4 });
            ui.text(ctx, "Saved areas", .{ .size = 25, .weight = .bold });
            ui.text(ctx, "A collection of places worth returning to", .{ .size = 12, .color = .hex(0x8393a7) });
            ui.end(ctx);
            ui.spacer(ctx);
            if (l.store) |store| ui.textf(ctx, .{ .size = 12, .color = .hex(0x7ee6d5) }, "{d} saved", .{store.records.items.len});
        }
        ui.divider(ctx);
        if (l.message) |message| ui.text(ctx, message, .{ .size = 12, .wrap = true, .color = .hex(0xffbf80) });
        const store = if (l.store) |*store| store else {
            ui.text(ctx, "Library unavailable. Existing files have not been changed.", .{ .wrap = true });
            return;
        };
        {
            ui.row(ctx, .{ .width = .fill, .grow = 1, .gap = 20 });
            defer ui.end(ctx);
            const available = @max(200, ctx.size.w - 48 - @as(f32, if (l.draft != null) 280 else 0));
            l.gallery(ctx, available);
            if (l.draft != null) l.editor(ctx);
        }
        ui.divider(ctx);
        if (if (l.draft == null) l.selected else null) |index| {
            const record = store.records.items[index];
            ui.row(ctx, .{ .width = .fill, .align_items = .center, .gap = 16 });
            defer ui.end(ctx);
            ui.column(ctx, .{ .grow = 1, .gap = 5, .clip = true });
            ui.text(ctx, short(ctx, record.name, 70), .{ .size = 14, .weight = .medium });
            ui.textf(ctx, .{ .size = 11, .color = .hex(0x8393a7) }, "{d}-bit coordinates  /  {d} iterations  /  {d} × {d}  /  {s}", .{ record.bits, record.iterations, record.width, record.height, paletteName(record.palette) });
            if (record.comment.len > 0) ui.text(ctx, short(ctx, record.comment, 100), .{ .size = 12, .color = .hex(0xa6b3c3), .wrap = true });
            ui.end(ctx);
            if (ui.button(ctx, "Open area", .{ .variant = .primary, .size = 12 }).clicked) l.activate(record);
        } else ui.text(ctx, "Click to select  ·  Double-click a thumbnail to explore", .{ .size = 12, .color = .hex(0x8393a7) });
    }
    fn activate(l: *Library, record: places.Record) void {
        if (l.load) |load| if (l.owner) |owner| load(owner, record);
    }
    fn gallery(l: *Library, ctx: *ui.Context, available: f32) void {
        ui.key(ctx, "gallery");
        ui.scroll(ctx, .{ .grow = 1, .height = .fill, .gap = 16, .padding = .{ .right = 8 } });
        defer ui.end(ctx);
        const store = &l.store.?;
        const count = store.records.items.len;
        if (count == 0) {
            ui.column(ctx, .{ .width = .fill, .height = .fill, .justify = .center, .align_items = .center, .gap = 10 });
            defer ui.end(ctx);
            ui.text(ctx, "Your next discovery belongs here", .{ .size = 19, .weight = .medium });
            ui.text(ctx, "Choose Save area in the explorer to begin your collection.", .{ .size = 12, .color = .hex(0x8393a7), .wrap = true });
            return;
        }
        const columns: usize = @intFromFloat(@max(1, @floor((available - 8 + 16) / 240)));
        const width = @min(320, (available - 8 - @as(f32, @floatFromInt(columns - 1)) * 16) / @as(f32, @floatFromInt(columns)));
        var row: usize = 0;
        while (row < count) : (row += columns) {
            ui.row(ctx, .{ .width = .fill, .gap = 16 });
            defer ui.end(ctx);
            for (row..@min(row + columns, count)) |position| {
                // Most recent discoveries first; keys remain tied to storage IDs.
                const index = count - position - 1;
                l.card(ctx, index, width);
            }
        }
    }
    fn card(l: *Library, ctx: *ui.Context, index: usize, width: f32) void {
        const record = l.store.?.records.items[index];
        const selected = l.selected == index;
        const key = ctx.print("place-{d}", .{index});
        ui.key(ctx, key);
        ui.column(ctx, .{ .width = .{ .px = width }, .gap = 0, .radius = 12, .clip = true, .background = .hex(0x111923), .border = if (selected) .hex(0x7ee6d5) else .hex(0x243040) });
        defer ui.end(ctx);
        {
            ui.key(ctx, "thumbnail");
            const it = ui.pressable(ctx, .{ .width = .fill, .height = .{ .px = width * 0.67 }, .clip = true, .background = .hex(0x182330), .control = true }, .hex(0x263b49));
            defer ui.end(ctx);
            cover(ctx, key, l.store.?.thumbnails.items[index], width, width * 0.67);
            if (it.clicked) {
                l.selected = index;
                ctx.changed = true;
                if (it.double_clicked) l.activate(record);
            }
        }
        ui.column(ctx, .{ .width = .fill, .padding = .all(13), .gap = 7 });
        defer ui.end(ctx);
        ui.text(ctx, short(ctx, record.name, 28), .{ .size = 15, .weight = .medium });
        {
            ui.row(ctx, .{ .width = .fill, .align_items = .center });
            defer ui.end(ctx);
            ui.textf(ctx, .{ .size = 13, .color = .hex(0x7ee6d5) }, "10^{d:.2}", .{record.zoom * @log10(2.0)});
            ui.spacer(ctx);
            ui.text(ctx, dateText(ctx, record.saved_at), .{ .size = 11, .color = .hex(0x8393a7) });
        }
    }
    fn editor(l: *Library, ctx: *ui.Context) void {
        ui.key(ctx, "save-editor");
        ui.column(ctx, .{ .width = .{ .px = 260 }, .height = .fill, .padding = .all(16), .gap = 12, .background = .hex(0x111923), .radius = 12 });
        defer ui.end(ctx);
        const draft = &l.draft.?;
        {
            ui.scroll(ctx, .{ .width = .fill, .grow = 1, .gap = 10 });
            defer ui.end(ctx);
            ui.text(ctx, "NEW DISCOVERY", .{ .size = 10, .weight = .bold, .color = .hex(0x7ee6d5) });
            ui.text(ctx, "Save this area", .{ .size = 20, .weight = .medium });
            _ = ui.image(ctx, .{ .key = ctx.print("draft-{d}", .{l.revision}), .bytes = draft.png, .max_width = 228, .max_height = if (ctx.size.h < 620) 90 else 160, .scale = 1, .radius = 8 });
            ui.text(ctx, "Name", .{ .size = 12, .color = .hex(0xa6b3c3) });
            _ = ui.textField(ctx, &l.name, .{ .width = .fill, .placeholder = "Area name" });
            ui.text(ctx, "Comment", .{ .size = 12, .color = .hex(0xa6b3c3) });
            _ = ui.textField(ctx, &l.comment, .{ .width = .fill, .placeholder = "An optional note…" });
        }
        if (ui.button(ctx, "Save to disk", .{ .variant = .primary, .width = .fill, .disabled = std.mem.trim(u8, l.name.text(), " \t\r\n").len == 0 }).clicked) {
            l.store.?.add(&draft.camera, draft.png, l.name.text(), l.comment.text(), draft.palette, draft.iterations, draft.width, draft.height) catch {
                l.message = "Saving failed. Check disk space and access to the library folder.";
                return;
            };
            draft.deinit();
            l.draft = null;
            l.selected = l.store.?.records.items.len - 1;
            l.message = "Area saved to disk.";
            ctx.changed = true;
        }
    }
    fn cover(ctx: *ui.Context, key: []const u8, png: []const u8, width: f32, height: f32) void {
        const hash = std.hash.Wyhash.hash(0x4d414e44454c, key);
        const info = ctx.text.images.info(hash, png) orelse {
            ui.text(ctx, "Preview unavailable", .{ .size = 12, .color = .hex(0x8393a7) });
            return;
        };
        const iw: f32 = @floatFromInt(info.width);
        const ih: f32 = @floatFromInt(info.height);
        const scale = @max(width / iw, height / ih);
        _ = ctx.leaf(.{ .absolute = true, .width = .{ .px = iw * scale }, .height = .{ .px = ih * scale }, .offset = .{ .x = (width - iw * scale) / 2, .y = (height - ih * scale) / 2 } }, .{ .image = .{ .key = hash, .bytes = png, .opacity = 1 } }, "preview-image");
    }
    fn short(ctx: *ui.Context, value: []const u8, max_chars: usize) []const u8 {
        var end: usize = 0;
        var chars: usize = 0;
        while (end < value.len and chars < max_chars) : (chars += 1) {
            end += @min(value.len - end, std.unicode.utf8ByteSequenceLength(value[end]) catch 1);
        }
        return if (end == value.len) value else ctx.print("{s}…", .{value[0..end]});
    }
    fn paletteName(palette: usize) []const u8 {
        return switch (palette) {
            1 => "Ember",
            2 => "Silver",
            else => "Tidal",
        };
    }
    fn dateText(ctx: *ui.Context, timestamp: i64) []const u8 {
        const date: std.time.epoch.EpochSeconds = .{ .secs = @intCast(std.math.clamp(timestamp, 0, 253402300799)) };
        const year = date.getEpochDay().calculateYearDay();
        const month = year.calculateMonthDay();
        const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
        return ctx.print("{d} {s} {d}", .{ @as(u32, month.day_index) + 1, months[@as(usize, @backingInt(month.month)) - 1], year.year });
    }
};

test "library preview, save action and reopen work without native windows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buf);
    const path = try std.fmt.allocPrint(g, "{s}/places.json", .{buf[0..len]});
    defer g.free(path);
    var library: Library = .{ .store = try places.Store.init(std.testing.io, path) };
    defer library.deinit();
    var cam = p.Camera.init();
    defer cam.deinit();
    cam.preset(1);
    const Job = @import("worker.zig").Job;
    const job = try Job.start(&cam, 320, 240, 1200, 0, 1);
    defer job.destroy();
    job.thread.?.join();
    job.thread = null;
    try library.capture(&cam, job.pixels, 320, 240, 0, 1200);
    library.name.set("Seahorse valley");
    library.comment.set("Fine spirals near the boundary");
    var tester: ui.Tester = undefined;
    try tester.init(std.testing.allocator, .init(&library, Library.view), .{ .width = 850, .height = 720, .dark = true });
    defer tester.deinit();
    // AppKit may paint once during view attachment before installing its sink.
    // Exercise the later CPU-atlas -> native-sink transition as well.
    tester.text.images.sink = .{ .ctx = &tester.renderer, .upload = @TypeOf(tester.renderer).uploadImage };
    try tester.clickText("Save to disk");
    try std.testing.expect(library.draft == null);
    try std.testing.expectEqual(@as(usize, 1), library.store.?.records.items.len);
    const shown = try tester.render(g);
    defer shown.deinit(g);
    var colorful: usize = 0;
    for (tester.ctx.nodes.items) |node| if (node.content == .image) {
        const x0: usize = @intFromFloat(@max(0, node.rect.x + 8) * tester.scale);
        const y0: usize = @intFromFloat(@max(0, node.rect.y + 8) * tester.scale);
        const x1: usize = @intFromFloat(@min(tester.size.w, node.rect.x + node.rect.w - 8) * tester.scale);
        const y1: usize = @intFromFloat(@min(tester.size.h, node.rect.y + node.rect.h - 8) * tester.scale);
        var y = y0;
        while (y < y1) : (y += 8) {
            var x = x0;
            while (x < x1) : (x += 8) {
                const px = shown.bytes[(y * shown.width + x) * 4 ..][0..4];
                if (@max(px[0], @max(px[1], px[2])) > 100) colorful += 1;
            }
        }
    };
    try std.testing.expect(colorful > 100);
    try tester.screenshot("/tmp/mandel-library.png");
    var reopened = try places.Store.init(std.testing.io, path);
    defer reopened.deinit();
    try std.testing.expectEqualStrings("Seahorse valley", reopened.records.items[0].name);
    try std.testing.expectEqualStrings("Fine spirals near the boundary", reopened.records.items[0].comment);
}

test "thumbnail pixels reach the native window image sink" {
    const Harness = struct {
        tester: *ui.Tester,
        png: []const u8,
        fn view(h: *@This(), ctx: *ui.Context) void {
            const Renderer = @TypeOf(h.tester.renderer);
            ctx.text.images.sink = .{ .ctx = &h.tester.renderer, .upload = Renderer.uploadImage };
            ui.column(ctx, .{ .width = .fill, .height = .fill });
            defer ui.end(ctx);
            _ = ui.image(ctx, .{ .key = "native-preview", .bytes = h.png, .scale = 1, .radius = 0 });
        }
    };
    var pixels: [32 * 32 * 4]u8 = undefined;
    for (0..32 * 32) |i| @memcpy(pixels[i * 4 ..][0..4], &[_]u8{ 35, 170, 240, 255 });
    const png = try ui.png.encode(g, .{ .bytes = &pixels, .width = 32, .height = 32 });
    defer g.free(png);
    var tester: ui.Tester = undefined;
    var harness: Harness = .{ .tester = &tester, .png = png };
    try tester.init(std.testing.allocator, .init(&harness, Harness.view), .{ .width = 64, .height = 64, .scale = 1 });
    defer tester.deinit();
    const rendered = try tester.render(g);
    defer rendered.deinit(g);
    try std.testing.expectEqualSlices(u8, &.{ 35, 170, 240, 255 }, rendered.bytes[(16 * 64 + 16) * 4 ..][0..4]);
}

test "gallery double-click opens the correct area once and adapts to window size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buf);
    const path = try std.fmt.allocPrint(g, "{s}/gallery.json", .{buf[0..len]});
    defer g.free(path);
    const Receiver = struct {
        count: usize = 0,
        zoom: f64 = 0,
        fn load(ptr: *anyopaque, record: places.Record) void {
            const r: *@This() = @ptrCast(@alignCast(ptr));
            r.count += 1;
            r.zoom = record.zoom;
        }
    };
    var receiver: Receiver = .{};
    var library: Library = .{ .store = try places.Store.init(std.testing.io, path), .owner = &receiver, .load = Receiver.load };
    defer library.deinit();
    var cam = p.Camera.init();
    defer cam.deinit();
    const names = [_][]const u8{ "The whole set", "Seahorse valley", "Spiral coast", "The endless edge", "Electric filaments", "Tidal islands" };
    const zooms = [_]f64{ 0, 16, 8, 4, 12, 24 };
    for (names, 0..) |name, i| {
        cam.preset(if (i < 4) i else 1);
        cam.zoom = zooms[i];
        cam.ensure();
        const job = try @import("worker.zig").Job.start(&cam, 320, 240, 1200, 0, 1);
        defer job.destroy();
        job.thread.?.join();
        job.thread = null;
        try library.capture(&cam, job.pixels, 320, 240, 0, 1200);
        try library.store.?.add(&cam, library.draft.?.png, name, if (i == 5) "Tiny islands surrounded by an intricate web of spirals." else "", 0, 1200, 320, 240);
    }
    library.draft.?.deinit();
    library.draft = null;
    var tester: ui.Tester = undefined;
    try tester.init(std.testing.allocator, .init(&library, Library.view), .{ .width = 1000, .height = 760, .theme = Library.theme() });
    defer tester.deinit();
    // The newest thumbnail is the first image; its center lies within its crop.
    var preview: ?ui.Rect = null;
    for (tester.ctx.nodes.items) |node| if (node.content == .image) {
        preview = node.rect;
        break;
    };
    const rect = preview.?;
    tester.click(rect.x + rect.w / 2, rect.y + rect.h / 2);
    try std.testing.expectEqual(@as(usize, 0), receiver.count);
    try std.testing.expectEqual(@as(?usize, 5), library.selected);
    tester.doubleClick(rect.x + rect.w / 2, rect.y + rect.h / 2);
    try std.testing.expectEqual(@as(usize, 1), receiver.count);
    try std.testing.expectEqual(@as(f64, 24), receiver.zoom);
    tester.frame();
    try std.testing.expectEqual(@as(usize, 1), receiver.count);
    try tester.screenshot("/tmp/mandel-gallery.png");
    try tester.clickText("Open area");
    try std.testing.expectEqual(@as(usize, 2), receiver.count);
    tester.resize(700, 520);
    tester.frame();
    const open = tester.findText("Open area").?;
    try std.testing.expect(open.y + open.h <= 520);
    try tester.screenshot("/tmp/mandel-gallery-small.png");
    const sample = &library.store.?.records.items[0];
    var solid: [64]u8 = undefined;
    for (0..16) |i| @memcpy(solid[i * 4 ..][0..4], &[_]u8{ 30, 120, 220, 255 });
    try library.capture(&cam, &solid, 4, 4, sample.palette, sample.iterations);
    tester.frame();
    const save = tester.findText("Save to disk").?;
    try std.testing.expect(save.y + save.h <= tester.size.h);
    try tester.screenshot("/tmp/mandel-gallery-editor.png");
}
