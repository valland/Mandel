const std = @import("std");
const p = @import("precision.zig");
const Reference = @import("reference.zig").Reference;
const GPU = @import("compute.zig").GPU;
pub const Engine = struct {
    reuse: @import("reuse.zig").Cache = .{},
    reference: ?Reference = null,
    revision: u64 = 0,
    gpu: ?GPU = null,
    attempted_gpu: bool = false,
    cpu_only: bool = false,
    references_built: usize = 0,
    pub fn deinit(e: *Engine) void {
        e.reuse.deinit();
        if (e.reference) |*r| r.deinit();
        if (e.gpu) |*g| g.deinit();
    }
    // Only one job may use an Engine at a time. Job completion uses release /
    // acquire ordering; the owner joins before destroying this cache.
    pub fn prepare(e: *Engine, cam: *const p.Camera, limit: u32, cancel: *const std.atomic.Value(bool)) !void {
        if (!e.cpu_only and !e.attempted_gpu) {
            e.attempted_gpu = true;
            e.gpu = GPU.init() catch |err| blk: {
                std.log.warn("Metal compute unavailable ({s}); using parallel CPU", .{@errorName(err)});
                break :blk null;
            };
        }
        if (e.reference) |*r| {
            if (r.valid(cam, limit)) return;
        }
        var fresh = try Reference.init(cam, limit, cancel);
        if (cancel.load(.acquire)) {
            fresh.deinit();
            return error.Cancelled;
        }
        if (e.reference) |*r| r.deinit();
        e.reference = fresh;
        e.revision += 1;
        e.references_built += 1;
    }
};
