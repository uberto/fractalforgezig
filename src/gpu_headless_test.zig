//! Test-only root for the headless GPU texture round-trip suite.
//!
//! Rooted in `src/` (NOT `src/gpu/`) so `gpu/texture.zig`'s `../c.zig` and
//! `../fractal/*` imports resolve inside the module path. This aggregates the
//! ONE C-linking test artifact; `zig build test` and `zig build test-gpu` build
//! it. The pure tier (`src/root.zig`) stays C-free and must not import this.
const std = @import("std");

test {
    _ = @import("gpu/texture.zig");
    std.testing.refAllDecls(@This());
}
