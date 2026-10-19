const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const p = @import("precision.zig");
const Job = @import("worker.zig").Job;
const display = @import("display.zig");
const cyan = ui.Color.hex(0x7ee6d5);

pub const State = struct {
    engine: @import("engine.zig").Engine = .{},
    window: ?*nanoui.Window = null,
    camera: p.Camera,
    frames: @import("frames.zig").Frames = .{},
    motion: @import("motion.zig").Motion = .{},
    last_time: f64 = -1,
    prefetch_job: bool = false,
    viewport: ui.Size = .{},
    viewport_scale: f32 = 0,
    gpu_used: bool = false,
    library: @import("library_ui.zig").Library = .{},
    save_pending: bool = false,
    direction: f64 = 1,
    temporal: bool = true,
    reused_pixels: usize = 0,
    job: ?*Job = null,
    generation: u64 = 1,
    dirty: bool = true,
    running: bool = false,
    speed: f32 = 2,
    detail: f32 = 1200,
    iteration_floor: u32 = 0,
    palette: usize = 0,
    render_seconds: f64 = 0,
    exact_pixels: usize = 0,
    render_width: u32 = 0,
    render_height: u32 = 0,
    last_mouse: ui.Point = .{},
    dragging: bool = false,
    error_message: ?[]const u8 = null,
    testing: bool = false,

    pub fn init() State {
        return .{ .camera = p.Camera.init() };
    }
    pub fn deinit(s: *State) void {
        if (s.job) |j| j.destroy();
        s.engine.deinit();
        s.frames.deinit();
        s.library.deinit();
        s.camera.deinit();
    }
    fn toggleJourney(s: *State) void {
        if (s.direction > 0 and !s.running and s.camera.zoom == 0 and s.camera.x.double() == -0.5 and s.camera.y.double() == 0) s.preset(1);
        s.running = !s.running;
        s.motion.velocity = 0;
        s.invalidate();
    }
    fn invalidate(s: *State) void {
        s.save_pending = false;
        s.frames.clearAhead();
        s.generation +%= 1;
        s.dirty = true;
        if (s.job) |j| j.cancel.store(true, .release);
    }
    fn preset(s: *State, index: usize) void {
        s.running = false;
        s.camera.preset(index);
        s.invalidate();
        s.frames.deinit();
        s.iteration_floor = 0;
    }
    fn collect(s: *State, ctx: *ui.Context) void {
        const j = s.job orelse return;
        if (!j.done.load(.acquire)) return;
        defer {
            j.destroy();
            s.job = null;
        }
        if (j.generation != s.generation or j.cancel.load(.acquire)) return;
        if (j.failed) {
            s.save_pending = false;
            s.error_message = "Render allocation failed. Try a smaller window.";
            s.running = false;
            return;
        }
        // Retry an almost entirely unresolved upcoming frame before showing
        // a black image. Bound automatic iteration growth; true interiors
        // must not cause an unbounded retry loop.
        if (s.running and j.unresolved_pixels * 100 > @as(usize, j.width) * j.height * 95 and j.limit < 32000) {
            s.iteration_floor = @min(32000, j.limit * 2);
            if (s.frames.base == null) s.dirty = true;
            return;
        }
        s.frames.accept(ctx, j, s.viewport, s.prefetch_job) catch {
            s.save_pending = false;
            s.error_message = "Could not upload the image.";
            s.running = false;
            return;
        };
        if (s.save_pending) {
            s.save_pending = false;
            const frame = &s.frames.base.?;
            s.library.capture(&frame.camera, frame.pixels, frame.width, frame.height, s.palette, j.limit) catch {
                s.error_message = "Could not create the preview.";
                return;
            };
            s.openLibrary();
        }
        s.render_seconds = j.seconds;
        s.reused_pixels = j.reused_pixels;
        s.exact_pixels = j.exact_pixels;
        s.gpu_used = j.gpu_used;
        s.error_message = null;
    }
    fn setDirection(s: *State, direction: f64) void {
        s.direction = direction;
        s.motion.velocity = 0;
        s.invalidate();
    }
    fn openLibrary(s: *State) void {
        s.library.owner = s;
        s.library.load = loadPlace;
        if (s.window) |win| s.library.open(win) catch {
            s.error_message = "Could not open the library.";
        };
    }
    fn loadPlace(ptr: *anyopaque, record: @import("places.zig").Record) void {
        const s: *State = @ptrCast(@alignCast(ptr));
        const cam = record.camera() catch {
            s.library.message = "Could not restore these coordinates.";
            return;
        };
        s.running = false;
        s.invalidate();
        s.frames.deinit();
        s.camera.deinit();
        s.camera = cam;
        s.palette = record.palette;
        s.detail = @floatFromInt(@min(10000, record.iterations));
        s.iteration_floor = record.iterations;
        if (s.window) |win| {
            win.redraw();
            if (!win.app.flags.hidden) win.focus();
        }
    }
    fn closed(ptr: *anyopaque, _: *nanoui.Window) void {
        const s: *State = @ptrCast(@alignCast(ptr));
        s.window = null;
        if (s.library.window) |win| win.close();
    }
    fn uploadImage(ptr: *anyopaque, x: u32, y: u32, w: u32, h: u32, pixels: []const u8) void {
        const s: *State = @ptrCast(@alignCast(ptr));
        if (s.window) |window| if (window.surface) |surface| display.queuedUpload(&surface.renderer, x, y, w, h, pixels);
    }
    fn navigationKey(ctx: *ui.Context, key: u8) bool {
        // macOS forwards unmodified printable keys through Input.chars;
        // modified/special keys use shortcut events. Consume either path
        // before a UI rebuild so a single Space toggles exactly once.
        if (ctx.focused_text != null) return false;
        const offered = ctx.shortcut(.{ .key = key });
        const typed = !ctx.input.cmd and !ctx.input.ctrl and !ctx.input.alt and
            ctx.input.chars.len == 1 and ctx.input.chars[0] == key;
        if (!offered and !typed) return false;
        ctx.input.chars = "";
        ctx.changed = true;
        return true;
    }
    pub fn view(s: *State, ctx: *ui.Context) void {
        if (ctx.text.images.sink != null and s.window != null) ctx.text.images.sink = .{ .ctx = s, .upload = uploadImage };
        s.collect(ctx);
        if (navigationKey(ctx, ' ')) s.toggleJourney();
        if (navigationKey(ctx, 'r')) s.preset(0);
        if (navigationKey(ctx, '+') or navigationKey(ctx, '=')) {
            s.running = false;
            s.camera.zoomAt(0.5, 0, 0);
            s.invalidate();
        }
        if (navigationKey(ctx, '-')) {
            s.running = false;
            s.camera.zoomAt(-0.5, 0, 0);
            s.invalidate();
        }
        ui.column(ctx, .{ .width = .fill, .height = .fill, .background = .hex(0x090d13), .padding = .all(22), .gap = 16 });
        defer ui.end(ctx);
        {
            ui.row(ctx, .{ .width = .fill, .align_items = .center, .gap = 12 });
            defer ui.end(ctx);
            ui.text(ctx, "M /", .{ .size = 29, .weight = .bold, .color = cyan });
            ui.text(ctx, "MANDEL", .{ .size = 22, .weight = .bold });
            ui.text(ctx, "A journey into the boundary", .{ .size = 13, .color = .hex(0x8393a7) });
            ui.spacer(ctx);
            ui.badge(ctx, "ZIG + NANOUI", cyan);
        }
        {
            ui.row(ctx, .{ .width = .fill, .height = .{ .px = @max(200, ctx.size.h - 126) }, .gap = 18 });
            defer ui.end(ctx);
            s.canvas(ctx);
            s.sidebar(ctx);
        }
        {
            ui.row(ctx, .{ .width = .fill, .align_items = .center, .gap = 14 });
            defer ui.end(ctx);
            ui.text(ctx, "Scroll to zoom  /  Drag to explore  /  Space to pause", .{ .size = 12, .color = .hex(0x8393a7) });
            ui.spacer(ctx);
            if (s.error_message) |message| ui.text(ctx, message, .{ .size = 12, .color = .hex(0xffa07a) }) else if (s.job) |j| {
                ui.textf(ctx, .{ .size = 12, .color = cyan }, "Rendering  {d}%", .{j.rows.load(.acquire) * 100 / j.height});
            } else ui.textf(ctx, .{ .size = 12, .color = .hex(0x8393a7) }, "{s}  /  {d} x {d}  /  {d:.0} ms", .{ if (s.gpu_used) "Metal" else "CPU", s.render_width, s.render_height, s.render_seconds * 1000 });
        }
        if (s.running or s.job != null) ctx.animationFrame();
    }
    fn canvas(s: *State, ctx: *ui.Context) void {
        ui.key(ctx, "canvas");
        const it = ui.pressable(ctx, .{ .grow = 1, .height = .fill, .clip = true, .radius = 12, .background = .hex(0x090c11), .border = .hex(0x253143) }, null);
        defer ui.end(ctx);
        const rect = it.rect orelse ui.Rect{ .w = @max(100, ctx.size.w - 298), .h = @max(100, ctx.size.h - 126) };
        if (it.hovered) {
            ctx.wants_wheel = true;
            ctx.wants_moves = true;
        }
        if (it.hovered and ctx.input.scroll.y != 0) {
            s.running = false;
            s.camera.zoomAt(std.math.clamp(@as(f64, ctx.input.scroll.y) * 0.012, -1, 1), (ctx.input.mouse.x - rect.x) / rect.w - 0.5, (ctx.input.mouse.y - rect.y - rect.h * 0.5) / rect.w);
            s.invalidate();
            ctx.input.scroll.y = 0;
        }
        if (it.hovered and ctx.input.pressed) {
            s.dragging = true;
            s.last_mouse = ctx.input.mouse;
            s.running = false;
        }
        if (s.dragging and ctx.input.down) {
            ctx.wants_moves = true;
            const dx = ctx.input.mouse.x - s.last_mouse.x;
            const dy = ctx.input.mouse.y - s.last_mouse.y;
            if (dx != 0 or dy != 0) {
                s.camera.pan(-dx / rect.w, -dy / rect.w);
                s.invalidate();
            }
            s.last_mouse = ctx.input.mouse;
        }
        if (!ctx.input.down) s.dragging = false;

        if (@abs(rect.w - s.viewport.w) > 1 or @abs(rect.h - s.viewport.h) > 1 or ctx.scale != s.viewport_scale) {
            s.viewport = .{ .w = rect.w, .h = rect.h };
            s.viewport_scale = ctx.scale;
            s.invalidate();
        }
        const dt = if (s.last_time < 0) 0 else @min(0.05, @max(0, ctx.time - s.last_time));
        s.last_time = ctx.time;
        if (s.running and !s.dirty) if (s.frames.coverageLimit(ctx.scale)) |limit| {
            const sustainable = if (s.render_seconds > 0) @min(@as(f64, s.speed), (if (s.temporal) @as(f64, 1) else 0.35) * 0.8 / s.render_seconds) else s.speed;
            var bound = if (s.direction > 0) limit else @max(-2, s.frames.base.?.camera.zoom);
            // A complete upcoming frame extends coverage now. Promotion below
            // happens before drawing, so crossing into it never exposes holes.
            if (s.temporal) if (s.frames.ahead) |next| {
                if (s.direction > 0 and next.camera.zoom <= limit) {
                    const next_density = @min(@as(f64, @floatFromInt(next.width)) / (next.viewport.w * ctx.scale), @as(f64, @floatFromInt(next.height)) / (next.viewport.h * ctx.scale));
                    bound = next.camera.zoom + @log2(@max(1, next_density / 1.15));
                } else if (s.direction < 0) bound = @max(-2, next.camera.zoom);
            };
            s.camera.zoom = s.motion.step(s.camera.zoom, bound, sustainable * s.direction, dt);
            if (s.direction < 0 and s.camera.zoom < -1.99999) {
                s.camera.zoom = -2;
                s.running = false;
            }
            s.camera.ensure();
        };
        s.frames.promote(ctx, s.camera.zoom) catch {
            s.error_message = "Could not upload the next frame.";
            s.running = false;
        };
        s.frames.draw(ctx, &s.camera, rect);
        const sampling: f32 = if (s.running) (if (s.temporal) @as(f32, 2.6) else 1.7) else 1;
        const width: u32 = @as(u32, @intFromFloat(@max(1, @ceil(rect.w * ctx.scale * sampling)))) | @as(u32, if (s.running and s.temporal) 1 else 0);
        const height: u32 = @as(u32, @intFromFloat(@max(1, @ceil(rect.h * ctx.scale * sampling)))) | @as(u32, if (s.running and s.temporal) 1 else 0);
        const prefetch = s.running and s.frames.base != null and s.frames.ahead == null and !s.dirty;
        if ((s.dirty or prefetch) and s.job == null and !s.testing) {
            var target = s.camera.clone();
            defer target.deinit();
            if (prefetch) {
                target.zoom = @max(-2, s.frames.base.?.camera.zoom + s.direction * (if (s.temporal) @as(f64, 1) else 0.35));
                target.ensure();
            } else if (s.running and s.direction < 0) target.zoom = @max(-2, target.zoom - (if (s.temporal) @as(f64, 1) else 0.35));
            const start: *const @TypeOf(startFull) = if (s.running and s.temporal) Job.startTemporal else startFull;
            s.job = start(&s.engine, &target, width, height, @intFromFloat(@max(@max(s.detail, @as(f64, @floatFromInt(s.iteration_floor))), target.zoom * 1.5 + 200)), s.palette, s.generation) catch {
                s.save_pending = false;
                s.error_message = "Could not start the renderer.";
                s.running = false;
                return;
            };
            s.prefetch_job = prefetch;
            s.render_width = width;
            s.render_height = height;
            s.dirty = false;
        }
    }
    fn startFull(engine: *@import("engine.zig").Engine, cam: *const p.Camera, w: u32, h: u32, limit: u32, palette: usize, generation: u64) anyerror!*Job {
        return Job.startCached(engine, cam, w, h, limit, palette, generation);
    }
    fn sidebar(s: *State, ctx: *ui.Context) void {
        ui.scroll(ctx, .{ .width = .{ .px = 236 }, .height = .fill, .padding = .all(18), .gap = 9, .background = .hex(0x111923), .radius = 12 });
        defer ui.end(ctx);
        ui.text(ctx, "EXPLORER", .{ .size = 11, .weight = .bold, .color = cyan });
        ui.textf(ctx, .{ .size = 30, .weight = .medium }, "10^{d:.1}", .{s.camera.zoom * @log10(2.0)});
        ui.textf(ctx, .{ .size = 12, .color = .hex(0x8393a7) }, "{d}-bit coordinates", .{s.camera.bits});
        if (ui.button(ctx, if (s.running) "Pause journey" else "Start journey", .{ .variant = .primary, .width = .fill }).clicked) s.toggleJourney();
        {
            ui.row(ctx, .{ .width = .fill, .gap = 6 });
            defer ui.end(ctx);
            if (ui.button(ctx, "Zoom in", .{ .width = .{ .px = 97 }, .size = 12, .variant = if (s.direction > 0) .primary else .secondary }).clicked) s.setDirection(1);
            if (ui.button(ctx, "Zoom out", .{ .width = .{ .px = 97 }, .size = 12, .variant = if (s.direction < 0) .primary else .secondary }).clicked) s.setDirection(-1);
        }
        ui.text(ctx, "ZOOM SPEED", .{ .size = 11, .color = .hex(0x8393a7) });
        _ = ui.slider(ctx, &s.speed, .{ .min = 0.1, .max = 8, .width = .fill });
        ui.textf(ctx, .{ .size = 12 }, "Up to {d:.1} octaves / second", .{s.speed});
        ui.divider(ctx);
        ui.text(ctx, "DESTINATIONS", .{ .size = 11, .color = .hex(0x8393a7) });
        const names = [_][]const u8{ "The whole set", "Seahorse valley", "Spiral coast", "The endless edge" };
        for (names, 0..) |name, index| if (ui.button(ctx, name, .{ .variant = .ghost, .width = .fill, .size = 12 }).clicked) s.preset(index);
        ui.divider(ctx);
        if (ui.button(ctx, switch (s.palette) {
            1 => "Palette: Ember",
            2 => "Palette: Silver",
            else => "Palette: Tidal",
        }, .{ .width = .fill, .size = 12 }).clicked) {
            s.palette = (s.palette + 1) % 3;
            s.invalidate();
        }
        ui.text(ctx, "Resolution: Native / Retina", .{ .size = 12, .color = cyan });
        ui.textf(ctx, .{ .size = 12 }, "Iteration budget: {d}", .{@as(u32, @intFromFloat(s.detail))});
        if (ui.slider(ctx, &s.detail, .{ .min = 200, .max = 10000, .width = .fill })) s.invalidate();
        ui.spacer(ctx);
        if (ui.button(ctx, if (s.save_pending) "Preparing preview..." else "Save area...", .{ .width = .fill, .size = 12, .disabled = s.library.store == null or s.save_pending }).clicked) {
            s.running = false;
            s.invalidate();
            s.save_pending = true;
        }
        if (ui.button(ctx, "Saved areas", .{ .width = .fill, .size = 12 }).clicked) s.openLibrary();
        ui.text(ctx, "Saved areas include a preview, metadata and an optional comment.", .{ .size = 11, .wrap = true, .color = .hex(0x8393a7) });
    }
};
pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "Mandel" });
    defer app.destroy();
    var state = State.init();
    defer state.deinit();
    const path = if (init.environ_map.get("MANDEL_LIBRARY_PATH")) |override| override else if (!app.flags.hidden) try std.fmt.allocPrint(init.arena.allocator(), "{s}/Library/Application Support/Mandel/places.json", .{init.environ_map.get("HOME") orelse return error.NoHomeDirectory}) else null;
    if (path) |file| {
        state.library.store = @import("places.zig").Store.init(init.io, file) catch null;
        if (state.library.store == null) state.library.message = "Could not read the library. Check its format and permissions. Saving is disabled to protect the existing file.";
    }
    state.window = try app.newWindow(.{ .title = "Mandel — Explore the infinite", .on_close = .{ .ctx = &state, .func = State.closed }, .width = 1180, .height = 820, .min_width = 820, .min_height = 760, .theme = theme(), .content = .{ .view = .init(&state, State.view) } });
    try app.run();
}
fn theme() ui.Theme {
    var t = ui.Theme.dark_theme;
    t.background = .hex(0x090d13);
    t.surface = .hex(0x1b2836);
    t.border = .hex(0x2b3c4e);
    t.accent = cyan;
    t.accent_hover = .hex(0xa0f3e5);
    t.accent_text = .hex(0x0b2927);
    return t;
}
test {
    _ = @import("precision.zig");
    _ = @import("fractal.zig");
    _ = @import("scaled.zig");
    _ = @import("prefix.zig");
    _ = @import("display.zig");
    _ = @import("compute_tests.zig");
    _ = @import("motion.zig");
}
test "native controls change camera, palette and zoom direction" {
    var state = State.init();
    defer state.deinit();
    state.testing = true;
    var tester: ui.Tester = undefined;
    try tester.init(std.testing.allocator, .init(&state, State.view), .{ .width = 1180, .height = 820, .theme = theme() });
    defer tester.deinit();
    try tester.clickText("Seahorse valley");
    try std.testing.expectEqual(@as(f64, 16), state.camera.zoom);
    try tester.clickText("Zoom out");
    try std.testing.expectEqual(@as(f64, -1), state.direction);
    try tester.clickText("Zoom in");
    try std.testing.expectEqual(@as(f64, 1), state.direction);
    try tester.clickText("Palette: Tidal");
    try std.testing.expectEqual(@as(usize, 1), state.palette);
    try tester.clickText("The whole set");
    try tester.clickText("Start journey");
    try std.testing.expect(state.running);
    try std.testing.expect(state.camera.zoom >= 16);
    try tester.clickText("Pause journey");
    try std.testing.expect(!state.running);
    tester.resize(820, 760);
    tester.frame();
    const footer = tester.findText("Scroll to zoom  /  Drag to explore  /  Space to pause").?;
    try std.testing.expect(footer.y + footer.h <= 760);
}
test "background rendering uploads a bounded image and produces a native screenshot" {
    var state = State.init();
    defer state.deinit();
    state.testing = true;
    var tester: ui.Tester = undefined;
    try tester.init(std.testing.allocator, .init(&state, State.view), .{ .width = 1180, .height = 820, .theme = theme(), .scale = 1 });
    defer tester.deinit();
    state.camera.preset(1);
    state.camera.zoom = 11;
    state.job = try Job.start(&state.camera, 800, 620, 800, 0, state.generation);
    state.job.?.thread.?.join();
    state.job.?.thread = null;
    tester.frame();
    try std.testing.expect(state.frames.base != null);
    try std.testing.expectEqual(@as(usize, 1), tester.text.images.decoded.count());
    try tester.screenshot("/tmp/mandel-preview.png");
    const pixels = tester.text.images.decoded.get(display.key).?.?.bgra;
    try display.upload(&tester.ctx, pixels, 800, 620);
    try std.testing.expectEqual(@as(usize, 1), tester.text.images.decoded.count());
    try std.testing.expectEqual(@as(usize, 800 * 620 * 4), tester.text.images.kept_bytes);
    var second: ui.Tester = undefined;
    try second.init(std.testing.allocator, .init(&state, State.view), .{ .width = 1180, .height = 820 });
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 1), second.text.images.decoded.count());
}

test "cancelled stale render cannot replace the current view" {
    var state = State.init();
    defer state.deinit();
    state.testing = true;
    var tester: ui.Tester = undefined;
    try tester.init(std.testing.allocator, .init(&state, State.view), .{ .width = 1180, .height = 820 });
    defer tester.deinit();
    state.camera.preset(3);
    state.camera.zoom = 1100;
    state.camera.ensure();
    state.job = try Job.start(&state.camera, 128, 80, 2000, 0, state.generation);
    state.preset(0);
    state.job.?.thread.?.join();
    state.job.?.thread = null;
    tester.frame();
    try std.testing.expect(state.job == null);
    try std.testing.expect(state.frames.base == null);
    try std.testing.expectEqual(@as(f64, 0), state.camera.zoom);
}

test "completed zoom frames replace one native-resolution surface" {
    var state = State.init();
    defer state.deinit();
    state.testing = true;
    var tester: ui.Tester = undefined;
    try tester.init(std.testing.allocator, .init(&state, State.view), .{ .width = 1180, .height = 820, .scale = 2 });
    defer tester.deinit();
    for (0..3) |i| {
        var target = state.camera.clone();
        defer target.deinit();
        target.zoom = @as(f64, @floatFromInt(i)) * 0.01;
        const j = try Job.start(&target, 64, 48, 200, 0, state.generation);
        j.thread.?.join();
        j.thread = null;
        defer j.destroy();
        try state.frames.accept(&tester.ctx, j, state.viewport, false);
        try std.testing.expectEqual(target.zoom, state.frames.base.?.camera.zoom);
        tester.frame();
    }
    try std.testing.expectEqual(@as(usize, 1), tester.text.images.decoded.count());
    try std.testing.expectEqual(@as(usize, 64 * 48 * 4), tester.text.images.kept_bytes);
}

test "prefetch holds camera geometry until promotion and reuses one texture" {
    var state = State.init();
    defer state.deinit();
    state.testing = true;
    var tester: ui.Tester = undefined;
    try tester.init(std.testing.allocator, .init(&state, State.view), .{ .width = 820, .height = 760, .scale = 2 });
    defer tester.deinit();
    for (0..2) |i| {
        var target = state.camera.clone();
        defer target.deinit();
        target.zoom += @as(f64, @floatFromInt(i)) * 0.35;
        const j = try Job.start(&target, 80, 60, 100, 0, 1);
        j.thread.?.join();
        j.thread = null;
        defer j.destroy();
        try state.frames.accept(&tester.ctx, j, .{ .w = 20, .h = 15 }, i == 1);
    }
    try std.testing.expectEqual(@as(f64, 0), state.frames.base.?.camera.zoom);
    try state.frames.promote(&tester.ctx, 0.34);
    try std.testing.expect(state.frames.ahead != null);
    try state.frames.promote(&tester.ctx, 0.35);
    try std.testing.expect(state.frames.ahead == null);
    try std.testing.expectEqual(@as(f64, 0.35), state.frames.base.?.camera.zoom);
    try std.testing.expectEqual(@as(usize, 1), tester.text.images.decoded.count());
    try std.testing.expect(state.frames.coverageLimit(2).? > 0.35);
}

test "saved-area action captures the exact view and restore cancels stale work" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buf);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/places.json", .{buf[0..len]});
    defer std.testing.allocator.free(path);
    var state = State.init();
    defer state.deinit();
    state.testing = true;
    state.library.store = try @import("places.zig").Store.init(std.testing.io, path);
    var tester: ui.Tester = undefined;
    try tester.init(std.testing.allocator, .init(&state, State.view), .{ .width = 1180, .height = 820, .theme = theme() });
    defer tester.deinit();
    state.camera.preset(1);
    state.palette = 2;
    state.running = true;
    try tester.clickText("Save area...");
    try std.testing.expect(state.save_pending and !state.running);
    state.job = try Job.start(&state.camera, 160, 120, 1200, state.palette, state.generation);
    state.job.?.thread.?.join();
    state.job.?.thread = null;
    tester.frame();
    const draft = &state.library.draft.?;
    try std.testing.expectEqual(state.camera.zoom, draft.camera.zoom);
    try std.testing.expectEqual(@as(c_int, 0), p.c.mpfr_cmp(&state.camera.x.v, &draft.camera.x.v));
    try state.library.store.?.add(&draft.camera, draft.png, "Captured area", "Saved by UI", draft.palette, draft.iterations, draft.width, draft.height);
    state.preset(0);
    state.job = try Job.start(&state.camera, 80, 60, 200, 0, state.generation);
    State.loadPlace(&state, state.library.store.?.records.items[0]);
    try std.testing.expect(state.job.?.cancel.load(.acquire));
    try std.testing.expect(state.frames.base == null);
    try std.testing.expectEqual(@as(f64, 16), state.camera.zoom);
    try std.testing.expectEqual(@as(usize, 2), state.palette);
    try std.testing.expectEqual(@as(u32, 1200), state.iteration_floor);
}

test "plain Space starts and stops once per event, including after button focus" {
    var state = State.init();
    defer state.deinit();
    state.testing = true;
    var tester: ui.Tester = undefined;
    try tester.init(std.testing.allocator, .init(&state, State.view), .{ .width = 1180, .height = 820, .theme = theme() });
    defer tester.deinit();
    tester.typeText(" ");
    try std.testing.expect(state.running);
    try std.testing.expectEqual(@as(f64, 16), state.camera.zoom);
    const generation = state.generation;
    tester.frame();
    tester.frame();
    try std.testing.expect(state.running);
    try std.testing.expectEqual(generation, state.generation);
    tester.typeText(" ");
    try std.testing.expect(!state.running);
    try tester.clickText("Start journey");
    tester.typeText(" ");
    try std.testing.expect(!state.running);
    tester.ctx.input.cmd = true;
    tester.typeText(" ");
    try std.testing.expect(!state.running);
    tester.ctx.input.cmd = false;
    try std.testing.expect(tester.shortcut(.{ .key = ' ' }));
    try std.testing.expect(state.running);
    tester.typeText("+");
    try std.testing.expect(!state.running);
    try std.testing.expectEqual(@as(f64, 16.5), state.camera.zoom);
    tester.typeText("-");
    try std.testing.expectEqual(@as(f64, 16), state.camera.zoom);
    tester.typeText("r");
    try std.testing.expectEqual(@as(f64, 0), state.camera.zoom);
}
