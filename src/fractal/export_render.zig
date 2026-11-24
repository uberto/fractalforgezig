//! Render a captured view into reusable bands in output image order.
const std = @import("std");
const geometry = @import("viewport.zig");
const gradient = @import("gradient.zig");
const mapping = @import("mapping.zig");
const iterbuf = @import("iterbuf.zig");
const colorpass = @import("colorpass.zig");
const perturb = @import("perturb.zig");

const mandelbrot = @import("mandelbrot.zig");
const autoiter = @import("autoiter.zig");

pub const Cancel = @import("render_cancel.zig").Cancel;

pub const Size = struct {
    width: u32,
    height: u32,

    pub fn validate(self: Size) error{InvalidDimensions}!void {
        if (self.width == 0 or self.height == 0 or self.width > 16_384 or self.height > 16_384 or
            @as(u64, self.width) * self.height > 100_000_000)
            return error.InvalidDimensions;
    }

    fn diagonal(self: Size) f64 {
        const w: f64 = @floatFromInt(self.width);
        const h: f64 = @floatFromInt(self.height);
        return @sqrt(w * w + h * h);
    }
};

pub const Snapshot = struct {
    view: geometry.SquareView,
    source: Size,
    lut: [gradient.lut_size]gradient.Rgba8,
    params: mapping.Params,
    interior: gradient.Rgba8,
    max_iter: u32,

    pub fn viewport(self: Snapshot, size: Size) error{ InvalidDimensions, InvalidSnapshot }!geometry.Viewport {
        try size.validate();
        if (self.source.width == 0 or self.source.height == 0 or
            self.max_iter == 0 or self.max_iter > autoiter.max_manual_iter)
            return error.InvalidSnapshot;

        const source = self.view.rectViewport(self.source.width, self.source.height);
        const diagonal = source.scale * self.source.diagonal();
        const scale = diagonal / size.diagonal();
        if (!std.math.isFinite(scale) or scale <= 0 or
            !std.math.isFinite(source.center_re) or !std.math.isFinite(source.center_im))
            return error.InvalidSnapshot;

        return .{
            .center_re = source.center_re,
            .center_im = source.center_im,
            .scale = scale,
            .width = size.width,
            .height = size.height,
        };
    }
};

pub const BandRenderer = struct {
    // At maximum width the smooth and RGBA buffers together occupy 1 MiB.
    pub const band_rows = 8;
    const pixel_block = 64;

    pub const Band = struct {
        first_row: u32,
        rows: u32,
        rgba: []const u8,
    };

    allocator: std.mem.Allocator,
    scene: Snapshot,
    vp: geometry.Viewport,
    orbit: ?perturb.ReferenceOrbit,
    smooth: []f32,
    rgba: []u8,
    next_row: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, scene: Snapshot, size: Size, cancel: ?Cancel) !BandRenderer {
        const vp = try scene.viewport(size);
        try Cancel.check(cancel);

        const pixels = try std.math.mul(usize, size.width, @min(size.height, band_rows));
        const rgba_bytes = try std.math.mul(usize, pixels, 4);
        const smooth = try allocator.alloc(f32, pixels);
        errdefer allocator.free(smooth);
        const rgba = try allocator.alloc(u8, rgba_bytes);
        errdefer allocator.free(rgba);

        const output_side = vp.scale * @as(f64, @floatFromInt(@min(size.width, size.height)));
        const center_magnitude = @max(@abs(vp.center_re), @abs(vp.center_im));
        const center_spacing = std.math.floatEps(f64) * center_magnitude;
        const deep = @min(scene.view.side, output_side) <= perturb.threshold_side or vp.scale <= center_spacing;
        return .{
            .allocator = allocator,
            .scene = scene,
            .vp = vp,
            // The iteration cap bounds each f64 component array to (1 << 24) + 1 entries.
            .orbit = if (deep) try perturb.ReferenceOrbit.computeCancellable(allocator, scene.view.center(), scene.max_iter, cancel) else null,
            .smooth = smooth,
            .rgba = rgba,
        };
    }

    pub fn deinit(self: *BandRenderer) void {
        if (self.orbit) |*orbit| orbit.deinit(self.allocator);
        self.allocator.free(self.rgba);
        self.allocator.free(self.smooth);
        self.* = undefined;
    }

    /// Return the next band with pixels borrowed until the next call or deinit.
    pub fn next(self: *BandRenderer, cancel: ?Cancel) !?Band {
        if (self.next_row == self.vp.height) return null;
        const rows = @min(self.vp.height - self.next_row, band_rows);
        const width = self.vp.width;

        for (0..rows) |row| {
            const y = self.next_row + @as(u32, @intCast(row));
            const py = @as(f64, @floatFromInt(y)) + 0.5;
            var x: u32 = 0;
            while (x < width) {
                try Cancel.check(cancel);
                const end = @min(x + pixel_block, width);
                const start = row * width + x;
                const count = end - x;
                const smooth = self.smooth[start..][0..count];
                for (smooth) |*value| {
                    value.* = if (self.orbit) |orbit| deep: {
                        const offset = iterbuf.pixelOffset(self.vp, x, y);
                        break :deep try perturb.iterateDeltaCancellable(orbit, offset.re, offset.im, self.scene.max_iter, cancel);
                    } else shallow: {
                        const px = @as(f64, @floatFromInt(x)) + 0.5;
                        const point = self.vp.pixelToComplex(px, py);
                        break :shallow try mandelbrot.iterateCancellable(point.re, point.im, self.scene.max_iter, cancel);
                    };
                    x += 1;
                }
                try colorpass.colorInto(self.rgba[start * 4 ..][0 .. count * 4], smooth, &self.scene.lut, self.scene.max_iter, self.scene.params, self.scene.interior);
            }
        }
        const first_row = self.next_row;
        self.next_row += rows;
        return .{ .first_row = first_row, .rows = rows, .rgba = self.rgba[0 .. @as(usize, rows) * width * 4] };
    }
};

fn fixture() Snapshot {
    var lut: [gradient.lut_size]gradient.Rgba8 = undefined;
    gradient.bakeLut(gradient.Gradient.fromStops(&.{
        .{ .pos = 0, .color = .{ 9, 46, 17, 255 } },
        .{ .pos = 1, .color = .{ 250, 220, 180, 255 } },
    }), &lut);
    return .{
        .view = geometry.SquareView.defaultView(),
        .source = .{ .width = 40, .height = 20 },
        .lut = lut,
        .params = .{ .mode = .cyclic, .period = 13, .banded = true },
        .interior = .{ 11, 22, 33, 255 },
        .max_iter = 153,
    };
}

test "invalid export dimensions win over allocation failure" {
    for ([_]Size{
        .{ .width = 1, .height = 0 },
        .{ .width = 0, .height = 1 },
        .{ .width = 1, .height = 16_385 },
        .{ .width = 16_385, .height = 1 },
        .{ .width = 10_001, .height = 10_000 },
    }) |size| {
        try std.testing.expectError(error.InvalidDimensions, BandRenderer.init(std.testing.failing_allocator, fixture(), size, null));
    }
}

test "dimension limits are inclusive" {
    for ([_]Size{
        .{ .width = 16_384, .height = 1 },
        .{ .width = 1, .height = 16_384 },
        .{ .width = 10_000, .height = 10_000 },
    }) |size| try size.validate();
}

test "export framing preserves source diagonal across aspect ratios" {
    for ([_]Size{
        .{ .width = 12, .height = 12 },
        .{ .width = 12, .height = 4 },
        .{ .width = 4, .height = 12 },
    }) |size| {
        const vp = try fixture().viewport(size);
        try std.testing.expectApproxEqAbs(@sqrt(7.0 * 7.0 + 3.5 * 3.5) / size.diagonal(), vp.scale, 1e-15);
    }
}

test "same aspect export preserves both spans at double resolution" {
    const low = try fixture().viewport(.{ .width = 40, .height = 20 });
    const high = try fixture().viewport(.{ .width = 80, .height = 40 });
    try std.testing.expectEqual(low.scale, high.scale * 2);
}

test "export samples pixel centers with real rightward and imaginary upward" {
    var scene = fixture();
    scene.view = try geometry.SquareView.fromCenterSide(.{ .re = -0.75, .im = 0.125 }, 3.5);
    const vp = try scene.viewport(.{ .width = 40, .height = 20 });
    const first = vp.pixelToComplex(0.5, 0.5);
    try std.testing.expectApproxEqAbs(-0.75 - 19.5 * 0.175, first.re, 1e-12);
    try std.testing.expectApproxEqAbs(0.125 + 9.5 * 0.175, first.im, 1e-12);
}

fn expectStitched(scene: Snapshot, comptime size: Size, deep: bool) !void {
    const alloc = std.testing.allocator;
    var renderer = try BandRenderer.init(alloc, scene, size, null);
    defer renderer.deinit();
    var actual: [size.width * size.height * 4]u8 = undefined;
    var offset: usize = 0;
    while (try renderer.next(null)) |band| {
        @memcpy(actual[offset..][0..band.rgba.len], band.rgba);
        offset += band.rgba.len;
    }

    const vp = try scene.viewport(size);
    var smooth: [size.width * size.height]f32 = undefined;
    if (deep) {
        var orbit = try perturb.ReferenceOrbit.compute(alloc, scene.view.center(), scene.max_iter);
        defer orbit.deinit(alloc);
        try iterbuf.iterateDeepBandInto(&smooth, vp, scene.max_iter, 0, size.height, &orbit);
    } else {
        try iterbuf.iterateInto(&smooth, vp, scene.max_iter);
    }
    var expected: [actual.len]u8 = undefined;
    try colorpass.colorInto(&expected, &smooth, &scene.lut, scene.max_iter, scene.params, scene.interior);
    try std.testing.expectEqualSlices(u8, &expected, actual[0..offset]);
}

test "stitched shallow bands match the full render" {
    try expectStitched(fixture(), .{ .width = 23, .height = 17 }, false);
}

test "stitched deep bands match the full precision render" {
    var scene = fixture();
    scene.view = try geometry.SquareView.fromCenterSide(.{
        .re = -0.743643887037158704752191506114774,
        .im = 0.131825904205311970493132056385139,
    }, 1e-30);
    scene.max_iter = 65_536;
    try expectStitched(scene, .{ .width = 11, .height = 17 }, true);
}

test "an enlarged export chooses perturbation when output samples need it" {
    var scene = fixture();
    scene.source = .{ .width = 4, .height = 4 };
    scene.view = try geometry.SquareView.fromCenterSide(.{ .re = 1e12, .im = 0 }, 0.01);
    var renderer = try BandRenderer.init(std.testing.allocator, scene, .{ .width = 100, .height = 100 }, null);
    defer renderer.deinit();
    try std.testing.expect(renderer.orbit != null);
}

const Stop = struct {
    remaining_checks: usize,

    fn control(self: *Stop) Cancel {
        return .{ .context = self, .isCancelled = requested };
    }

    fn requested(context: ?*anyopaque) bool {
        const self: *Stop = @ptrCast(@alignCast(context.?));
        self.remaining_checks -= 1;
        return self.remaining_checks == 0;
    }
};

test "cancellation interrupts reference orbit preparation" {
    var scene = fixture();
    scene.view = try geometry.SquareView.fromCenterSide(.{ .re = 0, .im = 0 }, 1e-30);
    scene.max_iter = 4096;
    var stop = Stop{ .remaining_checks = 2 };
    try std.testing.expectError(error.Cancelled, BandRenderer.init(std.testing.allocator, scene, .{ .width = 1, .height = 1 }, stop.control()));
}

fn expectPixelCancelled(deep: bool) !void {
    var scene = fixture();
    scene.view = try geometry.SquareView.fromCenterSide(.{ .re = 0, .im = 0 }, if (deep) 1e-30 else 1.0);
    scene.max_iter = 4096;
    var renderer = try BandRenderer.init(std.testing.allocator, scene, .{ .width = 1, .height = 1 }, null);
    defer renderer.deinit();
    var stop = Stop{ .remaining_checks = 2 };
    try std.testing.expectError(error.Cancelled, renderer.next(stop.control()));
}

test "cancellation interrupts a long shallow pixel" {
    try expectPixelCancelled(false);
}

test "cancellation interrupts a long deep pixel" {
    try expectPixelCancelled(true);
}

test "cancellation checks continue between blocks of short pixels" {
    var renderer = try BandRenderer.init(std.testing.allocator, fixture(), .{ .width = 65, .height = 1 }, null);
    defer renderer.deinit();
    var stop = Stop{ .remaining_checks = 2 };
    try std.testing.expectError(error.Cancelled, renderer.next(stop.control()));
}
