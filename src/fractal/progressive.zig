//! Pure PROGRESSIVE-PASS scheduler + the blocky-preview upsampler (M5).
//!
//! Why this exists: the full-resolution Mandelbrot pass takes long enough (hundreds of ms
//! to seconds in a Debug build) that running it inside one frame freezes the UI — no
//! progress, no repaint, no way to tell the app is working. This module holds the two pure
//! pieces that let the edge (`main.zig`) run that same pass in per-frame CHUNKS instead:
//!
//!   * `Pass` — how far the pass has got (`rows_done` of `rows_total`), how many rows to
//!     attempt next, and the `fraction` the status bar shows. `advance` re-times the chunk
//!     size from the measured cost of the previous one so each chunk costs ~`target_chunk_ns`
//!     regardless of `max_iter`, image width, or machine speed.
//!   * `upsampleInto` — nearest-neighbour block copy of a smooth-value buffer into a bigger
//!     (or smaller) one. The edge seeds the freshly allocated full-res buffer with the coarse
//!     preview through this, so the first frame of a pass shows a BLOCKY version of the new
//!     view instead of black, and rows sharpen into it as the chunks land.
//!
//! Everything here is PURE: no clock (the caller measures and passes `elapsed_ns`), no
//! allocation, no SDL/GPU/ImGui, no global state. It lives in the fast `zig build test` tier.
const std = @import("std");

/// Errors returned by `upsampleInto`.
pub const UpsampleError = error{
    /// `dst.len != dst_w * dst_h` or `src.len != src_w * src_h`. Returned rather than
    /// writing out of bounds (mirrors `iterbuf.IterError.BufferSizeMismatch`).
    BufferSizeMismatch,
    /// One of the four dimensions was 0, which has no pixels to sample or fill.
    DegenerateSize,
};

/// Wall-clock cost one chunk should aim for — the repaint interval DURING a render, and also
/// the worst-case input lag (an event is handled between chunks, not inside one).
///
/// 500 ms, not one display frame: this is a fractal renderer, not a game. A ~2 fps progress
/// bar reads as "working" perfectly well, and a chunk two orders of magnitude longer than a
/// frame amortises the per-chunk overhead — the recolor of the band, and on the GPU path a
/// whole dispatch + download per chunk — over far more useful work. The adaptive sizing can
/// overshoot when a band turns out costlier than the one it was timed from, capped at 4×
/// growth, so the practical worst case is a second or two.
pub const target_chunk_ns: u64 = 500_000_000;

/// Rows in the FIRST chunk of a pass, before any measurement exists. Deliberately small: an
/// over-long first chunk is a visible stall, whereas a too-short one only costs one frame —
/// and the ramp (≤4× per chunk) reaches the budget in a handful of cheap chunks.
pub const initial_chunk_rows: u32 = 4;

/// Upper bound on a chunk, so a very cheap view (deep interior, low `max_iter`) cannot ramp
/// up to a chunk so large it stalls the frame anyway.
pub const max_chunk_rows: u32 = 4096;

/// One in-flight progressive pass: `rows_done` of `rows_total` image rows are final; the
/// rest still hold the seeded preview. The owner (`engine.Engine.pass`) creates it with
/// `.{ .rows_total = image_h }` and drives it with `nextChunk` / `advance`.
pub const Pass = struct {
    /// Total image rows this pass must iterate (the image height).
    rows_total: u32,
    /// Rows already iterated at full resolution, counted from the top.
    rows_done: u32 = 0,
    /// Rows to attempt in the next chunk; re-timed by `advance`.
    chunk_rows: u32 = initial_chunk_rows,

    /// Completion in `[0, 1]` for the progress bar. A zero-row pass reads as complete.
    pub fn fraction(self: Pass) f32 {
        if (self.rows_total == 0) return 1.0;
        const done_f: f32 = @floatFromInt(@min(self.rows_done, self.rows_total));
        const total_f: f32 = @floatFromInt(self.rows_total);
        return done_f / total_f;
    }

    /// Whether every row has been iterated (the edge then bumps the counters and clears
    /// the pass).
    pub fn done(self: Pass) bool {
        return self.rows_done >= self.rows_total;
    }

    /// Rows the next chunk should iterate: the adaptive `chunk_rows`, never 0, clamped to
    /// what is left so a chunk can never run past the last row.
    pub fn nextChunk(self: Pass) u32 {
        const remaining = self.rows_total - @min(self.rows_done, self.rows_total);
        return @min(@max(self.chunk_rows, 1), remaining);
    }

    /// Record that `rows` rows took `elapsed_ns`, and re-time the next chunk from that
    /// measurement. `rows_done` saturates at `rows_total`.
    pub fn advance(self: *Pass, rows: u32, elapsed_ns: u64) void {
        self.rows_done = @min(self.rows_done +| rows, self.rows_total);
        self.chunk_rows = adaptChunkRows(rows, elapsed_ns, target_chunk_ns);
    }
};

/// Rows the next chunk should attempt, given that `rows` rows cost `elapsed_ns`: scale the
/// row count so the next chunk lands on `target_ns`. Guards, in order:
///   * `rows == 0` (nothing measured) → start over at `initial_chunk_rows`.
///   * `elapsed_ns == 0` (too fast for the timer's resolution) → grow by the 4× cap.
///   * growth is capped at 4× per chunk so one suspiciously fast chunk (an all-exterior band
///     that escapes immediately) cannot produce a chunk that overruns the budget 100×.
///   * the result is clamped to `1 .. max_chunk_rows`, so a pass always makes progress.
pub fn adaptChunkRows(rows: u32, elapsed_ns: u64, target_ns: u64) u32 {
    if (rows == 0) return initial_chunk_rows;
    const growth_cap: u64 = @as(u64, rows) * 4;
    if (elapsed_ns == 0) return @intCast(@min(growth_cap, @as(u64, max_chunk_rows)));
    const scaled = (@as(u64, rows) * target_ns) / elapsed_ns;
    const capped = @min(scaled, growth_cap);
    return @intCast(std.math.clamp(capped, @as(u64, 1), @as(u64, max_chunk_rows)));
}

/// Bytes that fit any `progressLabel` result (including its null terminator).
pub const progress_label_buf_len: usize = 24;

/// The status-bar label for a pass at completion `f`: `"rendering 42%"`. Null-terminated so
/// the ImGui edge can hand it straight to `igProgressBar` without a second copy. `f` is
/// clamped to `[0, 1]`, so a caller cannot print a nonsensical percentage.
pub fn progressLabel(buf: []u8, f: f32) ![:0]u8 {
    const clamped = std.math.clamp(f, 0.0, 1.0);
    const pct: u32 = @intFromFloat(@round(clamped * 100.0));
    return std.fmt.bufPrintZ(buf, "rendering {d}%", .{pct});
}

/// Which control the progress area offers beside the percentage, given the render state.
pub const StatusControl = enum {
    /// A full-resolution render is in flight: offer to stop it.
    cancel,
    /// A render was cancelled and not restarted: offer to render the same view again.
    render,
    /// Nothing to offer — no render in flight and none cancelled.
    none,
};

/// The control the status area should show: `.cancel` while a render is in flight, `.render`
/// once one has been cancelled and not restarted, and `.none` otherwise. `rendering` wins over
/// `cancelled` (a fresh render supersedes a stale cancel), so the pure edge in `main.zig` can
/// pick the button and its action from one call. Beside `progressLabel` because both turn the
/// same render state into the progress area's UI.
pub fn statusControl(rendering: bool, cancelled: bool) StatusControl {
    if (rendering) return .cancel;
    if (cancelled) return .render;
    return .none;
}

/// Nearest-neighbour resample of a smooth-value buffer: fill `dst` (`dst_w × dst_h`) by
/// sampling `src` (`src_w × src_h`) proportionally. Used to seed a new render buffer with
/// the previous (usually coarse) image so the pass starts from a BLOCKY preview of the same
/// view rather than from black — see the file header.
///
/// Proportional sampling (`sx = x * src_w / dst_w`) is deliberate: the coarse and full-res
/// buffers of one view have the same aspect, so the preview lands on the same complex region
/// the finished pass will. Pure: no allocation, no clock. Rejects degenerate dimensions and
/// mis-sized buffers instead of writing out of bounds.
pub fn upsampleInto(
    dst: []f32,
    dst_w: u32,
    dst_h: u32,
    src: []const f32,
    src_w: u32,
    src_h: u32,
) UpsampleError!void {
    if (dst_w == 0 or dst_h == 0 or src_w == 0 or src_h == 0) return UpsampleError.DegenerateSize;
    if (dst.len != @as(usize, dst_w) * @as(usize, dst_h)) return UpsampleError.BufferSizeMismatch;
    if (src.len != @as(usize, src_w) * @as(usize, src_h)) return UpsampleError.BufferSizeMismatch;

    var y: u32 = 0;
    while (y < dst_h) : (y += 1) {
        const sy: usize = @intCast((@as(u64, y) * @as(u64, src_h)) / @as(u64, dst_h));
        const src_row = sy * @as(usize, src_w);
        const dst_row = @as(usize, y) * @as(usize, dst_w);
        var x: u32 = 0;
        while (x < dst_w) : (x += 1) {
            const sx: usize = @intCast((@as(u64, x) * @as(u64, src_w)) / @as(u64, dst_w));
            dst[dst_row + x] = src[src_row + sx];
        }
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────
// Pure and deterministic: no clock (elapsed times are supplied), no allocation beyond
// stack arrays, no shared state. One assertion of intent per test.

test "Pass.fraction is 0 before the first chunk" {
    const p = Pass{ .rows_total = 200 };
    try std.testing.expectEqual(@as(f32, 0.0), p.fraction());
}

test "Pass.fraction is the completed row ratio mid-pass" {
    const p = Pass{ .rows_total = 200, .rows_done = 50 };
    try std.testing.expectEqual(@as(f32, 0.25), p.fraction());
}

test "Pass.fraction is 1 for a degenerate zero-row pass" {
    const p = Pass{ .rows_total = 0 };
    try std.testing.expectEqual(@as(f32, 1.0), p.fraction());
}

test "Pass.done is false while rows remain" {
    const p = Pass{ .rows_total = 10, .rows_done = 9 };
    try std.testing.expect(!p.done());
}

test "Pass.done is true once every row is iterated" {
    const p = Pass{ .rows_total = 10, .rows_done = 10 };
    try std.testing.expect(p.done());
}

test "Pass.nextChunk clamps the chunk to the rows that are left" {
    const p = Pass{ .rows_total = 10, .rows_done = 8, .chunk_rows = 64 };
    try std.testing.expectEqual(@as(u32, 2), p.nextChunk());
}

test "Pass.nextChunk never returns zero rows" {
    const p = Pass{ .rows_total = 10, .rows_done = 0, .chunk_rows = 0 };
    try std.testing.expectEqual(@as(u32, 1), p.nextChunk());
}

test "Pass.advance saturates rows_done at rows_total" {
    var p = Pass{ .rows_total = 10, .rows_done = 8 };
    p.advance(5, target_chunk_ns);
    try std.testing.expectEqual(@as(u32, 10), p.rows_done);
}

test "Pass.advance re-times the next chunk from the measured cost" {
    // 8 rows in half the budget ⇒ the next chunk may attempt twice as many.
    var p = Pass{ .rows_total = 1000 };
    p.advance(8, target_chunk_ns / 2);
    try std.testing.expectEqual(@as(u32, 16), p.chunk_rows);
}

test "adaptChunkRows shrinks the chunk when the measured chunk overran the budget" {
    // 40 rows took 4× the budget ⇒ aim for a quarter of them.
    try std.testing.expectEqual(@as(u32, 10), adaptChunkRows(40, target_chunk_ns * 4, target_chunk_ns));
}

test "adaptChunkRows never shrinks below one row" {
    try std.testing.expectEqual(@as(u32, 1), adaptChunkRows(1, target_chunk_ns * 1000, target_chunk_ns));
}

test "adaptChunkRows caps growth at 4x even when the chunk was unmeasurably fast" {
    try std.testing.expectEqual(@as(u32, 32), adaptChunkRows(8, 0, target_chunk_ns));
}

test "adaptChunkRows caps the chunk at max_chunk_rows" {
    try std.testing.expectEqual(max_chunk_rows, adaptChunkRows(max_chunk_rows, 1, target_chunk_ns));
}

test "adaptChunkRows falls back to the initial chunk when nothing was measured" {
    try std.testing.expectEqual(initial_chunk_rows, adaptChunkRows(0, target_chunk_ns, target_chunk_ns));
}

test "progressLabel renders the completion percentage" {
    var buf: [progress_label_buf_len]u8 = undefined;
    try std.testing.expectEqualStrings("rendering 42%", try progressLabel(&buf, 0.42));
}

test "progressLabel clamps an out-of-range fraction to 100%" {
    var buf: [progress_label_buf_len]u8 = undefined;
    try std.testing.expectEqualStrings("rendering 100%", try progressLabel(&buf, 1.7));
}

test "acceptance: statusControl offers cancel while rendering, render after a cancel, neither otherwise" {
    // While a full pass runs the status area offers Cancel; once the user has cancelled (and it is
    // not running) it offers Render to restart; with nothing to act on it offers neither.
    try std.testing.expectEqual(StatusControl.cancel, statusControl(true, false));
    try std.testing.expectEqual(StatusControl.cancel, statusControl(true, true));
    try std.testing.expectEqual(StatusControl.render, statusControl(false, true));
    try std.testing.expectEqual(StatusControl.none, statusControl(false, false));
}

test "upsampleInto replicates each source value over its destination block" {
    const src = [_]f32{ 1.0, 2.0, 3.0, 4.0 }; // 2×2
    var dst: [16]f32 = undefined; // 4×4 ⇒ 2×2 blocks
    try upsampleInto(&dst, 4, 4, &src, 2, 2);
    const expected = [_]f32{
        1.0, 1.0, 2.0, 2.0,
        1.0, 1.0, 2.0, 2.0,
        3.0, 3.0, 4.0, 4.0,
        3.0, 3.0, 4.0, 4.0,
    };
    try std.testing.expectEqualSlices(f32, &expected, &dst);
}

test "upsampleInto also downsamples (a smaller destination samples proportionally)" {
    const src = [_]f32{
        1.0, 1.0, 2.0, 2.0,
        1.0, 1.0, 2.0, 2.0,
        3.0, 3.0, 4.0, 4.0,
        3.0, 3.0, 4.0, 4.0,
    }; // 4×4
    var dst: [4]f32 = undefined; // 2×2
    try upsampleInto(&dst, 2, 2, &src, 4, 4);
    try std.testing.expectEqualSlices(f32, &[_]f32{ 1.0, 2.0, 3.0, 4.0 }, &dst);
}

test "upsampleInto is an exact copy when the dimensions match" {
    const src = [_]f32{ -1.0, 0.5, 7.0, 9.0 };
    var dst: [4]f32 = undefined;
    try upsampleInto(&dst, 2, 2, &src, 2, 2);
    try std.testing.expectEqualSlices(f32, &src, &dst);
}

test "upsampleInto rejects a destination whose length is not dst_w * dst_h" {
    const src = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    var dst: [15]f32 = undefined; // one short of 4×4
    try std.testing.expectError(UpsampleError.BufferSizeMismatch, upsampleInto(&dst, 4, 4, &src, 2, 2));
}

test "upsampleInto rejects a source whose length is not src_w * src_h" {
    const src = [_]f32{ 1.0, 2.0, 3.0 }; // claims 2×2
    var dst: [16]f32 = undefined;
    try std.testing.expectError(UpsampleError.BufferSizeMismatch, upsampleInto(&dst, 4, 4, &src, 2, 2));
}

test "upsampleInto rejects a degenerate zero dimension" {
    const src = [_]f32{1.0};
    var dst: [1]f32 = undefined;
    try std.testing.expectError(UpsampleError.DegenerateSize, upsampleInto(&dst, 1, 1, &src, 1, 0));
}
