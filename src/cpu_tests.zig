//! The hosted CI subset; the full `test` step also exercises Metal and native UI.
test {
    _ = @import("precision.zig");
    _ = @import("fractal.zig");
    _ = @import("scaled.zig");
    _ = @import("prefix.zig");
    _ = @import("motion.zig");
    _ = @import("places.zig");
}
