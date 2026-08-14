//! The DECOUPLING engine — the crux of M2's guarantee and of M3's navigation. It owns the
//! CPU-side render state (the view, the image side `S`, the `max_iter` policy, the
//! persistent smooth-value buffer, the palette + its LUT and the RGBA8 output) and nothing
//! else: the app (T5/T6/T7) owns the window, the texture upload and the input.
//!
//! THE GUARANTEE (plan constraint, re-pinned for M3): editing the palette or mapping reruns
//! ONLY the cheap color pass — it NEVER re-runs the expensive Mandelbrot iteration. Two
//! counters make that observable and testable:
//!   * `iteration_passes` — bumped ONLY by a completed iteration of the smooth buffer: by
//!     `iterate` (the one-shot path, reached through `setViewport`, `setPolicy` and `resize`)
//!     or by the final chunk of a progressive pass (`beginPass` → `stepPass`, M5), which is
//!     the SAME iteration split across frames and so counts exactly once. Both are refills
//!     of the `[]f32` buffer, i.e. exactly the inputs the iteration depends on.
//!   * `color_passes`     — bumped by every recolor: each of the above (they recolor too)
//!     and each of `setGradient` / `setMapping` / `setInterior`.
//! A palette/mapping edit therefore bumps `color_passes` while `iteration_passes` stays put,
//! even when it follows a navigation — asserted directly in the tests below.
//!
//! `max_iter` has ONE source of truth: T3's `autoiter.IterPolicy.effective`. The engine
//! recomputes `max_iter` from `policy` + `view.magnification()` at the top of EVERY
//! iteration, so the stored value can never be stale, and its log line renders the number
//! through `autoiter.policySummary` — the same `effective` call — so the summary can never
//! advertise a count the render did not use.
//!
//! Composition (no reimplementation): `viewport.SquareView.imageViewport` (T1) is the ONE
//! bridge from the M3 view to the image `Viewport` that `iterbuf.iterateInto` (M2) iterates;
//! `gradient.bakeLut` bakes the LUT; `mapping.Params` selects the transform;
//! `colorpass.colorInto` writes the RGBA8 output. This module adds only the persistent
//! state, the counters, the resize, and the pure summary/message builders.
//!
//! Failure paths return TYPED errors, never `unreachable` and never swallowed: a degenerate
//! view → `viewport.ViewportError.DegenerateRegion`; a zero image side →
//! `EngineError.DegenerateImageSide`; a magnification the auto ramp cannot use →
//! `autoiter.AutoIterError.InvalidMagnification`; a failed buffer (re)allocation →
//! `error.OutOfMemory` with the requested size; an empty gradient →
//! `EngineError.EmptyGradient`; a mis-sized internal buffer surfaces the composed modules'
//! `BufferSizeMismatch`.
//!
//! LOGGING — the ONE exception to `src/fractal/`'s log-free rule, required by the milestone
//! plan's standing requirements ("the engine logs a one-line summary on re-iterate ...
//! failure paths log `std.log.err`/`warn` with actionable context and return a Zig error").
//! `std.log` is stdlib (no SDL/GPU/ImGui), so this module still compiles and runs in the
//! fast `zig build test` tier. Every logged string comes from a PURE, unit-tested builder
//! (`iteratePassSummary`, `colorPassSummary`, `degenerateViewMessage`, `imageSideMessage`,
//! `resizeFailureMessage`, plus T1's `viewport.degenerateRegionMessage` and T3's
//! `autoiter.maxIterRangeMessage`); the call sites stay one line. Sibling modules
//! (`viewport`, `navigate`, `autoiter`, `iterbuf`, `colorpass`) remain log-free.
//!
//! One tooling caveat, spelled out at `emitErr`: the `.err` EMISSION (not the message, not
//! the returned error) is suppressed under `builtin.is_test`, because Zig's test runner
//! treats any logged error as a failed test and this module's failure paths are themselves
//! acceptance criteria. The wording is pinned by the builder tests instead.
//!
//! M6 — THE PATH DECISION LIVES HERE, and so does the reference orbit. `iterbuf` offers two
//! iteration paths (`iterateRowsInto`, the proven direct `f64` one, and
//! `iterateDeepBandInto`, T3's perturbation one) and chooses between them never; this module
//! chooses, ONCE, in `usesDeepPath` — a view at or below `perturb.threshold_side` is deep.
//! Both the one-shot `iterate` and the progressive `stepPassRows` route their CPU work
//! through the single `cpuIterateBand`, so the two can not drift apart and a progressive deep
//! render is scalar-identical to a one-shot one.
//!
//! The orbit is ENGINE-OWNED and per-RENDER, never cached across renders: `ensureOrbit`
//! computes it lazily on the first band that needs it, every render boundary
//! (`iterate`, `beginPass`, `cancelPass`, `finishPass`, `deinit`) releases it, and a progressive
//! pass of N chunks therefore computes exactly ONE orbit — the expensive `f128` loop — and
//! shares it across all N. `orbit_computations` and `path_summaries` count those two
//! once-per-render facts so tests can assert them by number instead of by eye.
const std = @import("std");
const builtin = @import("builtin");
const viewport = @import("viewport.zig");
const iterbuf = @import("iterbuf.zig");
const gradient = @import("gradient.zig");
const mapping = @import("mapping.zig");
const colorpass = @import("colorpass.zig");
const color = @import("color.zig");
const autoiter = @import("autoiter.zig");
const progressive = @import("progressive.zig");
const perturb = @import("perturb.zig");

const Viewport = viewport.Viewport;
const SquareView = viewport.SquareView;
const IterPolicy = autoiter.IterPolicy;

/// The fractal core's log scope (see the file header for why this module may log at all).
const log = std.log.scoped(.fractal);

/// Reused verbatim from `color.zig` (M0). Channel order R, G, B, A. Do not redefine.
pub const Rgba8 = color.Rgba8;

/// Errors this module defines itself. The composed modules' errors are re-exported through
/// `IterateError` / `ResizeError` below, so callers match one set per operation.
pub const EngineError = error{
    /// A supplied `Gradient` had zero stops; the LUT bake requires at least one. Returned
    /// (not asserted) so a bad edit fails loudly and testably rather than tripping a
    /// debug assert inside `gradient.bakeLut`.
    EmptyGradient,
    /// An internal buffer's length did not match the view (`iter.len != S*S` or
    /// `rgba.len != iter.len*4`). Surfaced from `iterbuf`/`colorpass` rather than an
    /// out-of-bounds write. `init`/`resize` size both buffers correctly, so this only
    /// fires if a caller corrupts the slices — but it is a returned error, never an
    /// `unreachable`, matching the milestone's "no unreachable on failure paths" rule.
    BufferSizeMismatch,
    /// The requested square image side was 0 px, which has no pixels to iterate and no
    /// pixel↔complex mapping (T1's `imageViewport` requires `S > 0`). T5 hits this when the
    /// window is minimized; report it with `imageSideMessage` and skip the pass.
    DegenerateImageSide,
};

/// Everything an iteration path (`iterate`, `setViewport`, `setPolicy`) can return: this
/// module's own failures, T1's degenerate-view rejection and T3's `max_iter` rejections.
/// `colorpass.ColorError` folds in as `BufferSizeMismatch`; `iterbuf.IterError` folds in
/// whole, so M5's row-band path can surface `RowRangeOutOfBounds` under its own name rather
/// than being flattened into a size mismatch it is not.
/// M6 folds in `OrbitFailure`: a deep view's iteration cannot start until its reference orbit
/// exists, so `OutOfMemory` (the orbit is `max_iter + 1` f64 pairs) and `NonFiniteCenter` are
/// now outcomes of an ITERATION, not only of a resize. Reported by `orbitFailureMessage`.
pub const IterateError = EngineError || viewport.ViewportError || autoiter.AutoIterError ||
    iterbuf.IterError || OrbitFailure;

/// Everything computing this render's reference orbit can fail with: T3's own rejection plus
/// the allocation. Named so `orbitFailureMessage`'s buffer bound is derived from the error set
/// rather than guessed.
pub const OrbitFailure = perturb.OrbitError || std.mem.Allocator.Error;

/// `IterateError` plus allocation failure — what the paths that (re)allocate the buffers
/// (`init`, `resize`) can return.
pub const ResizeError = IterateError || std.mem.Allocator.Error;

/// Function signature for the iteration backend (CPU or GPU). It iterates ONE ROW BAND:
/// rows `y0 .. y0+rows` of an `image_w x image_h` image, writing `iter_band` — the band
/// ALONE, exactly `rows * image_w` values from index 0. The whole image is the band
/// `(0, image_h)`.
///
/// The band is what lets the progressive pass chunk the GPU the same way it chunks the CPU;
/// a whole-image-only backend would either freeze the frame or, at a high `max_iter`, run
/// long enough for the GPU's command-buffer watchdog to abort it.
///
/// GPU path: `compute.gpuIterateRows` wrapped in a thin free function in `main.zig`.
/// CPU path: the built-in `iterbuf.iterateRowsInto` adapter.
/// `anyerror` so GPU errors (SDL failures) propagate without widening IterateError.
///
/// M6 adds `orbit`: non-null means the engine decided this view needs the DEEP path and has
/// already computed the one reference orbit for the whole render, so the backend must iterate
/// perturbatively against it (`iterbuf.iterateDeepBandInto`) rather than direct-iterating `c`
/// — at these depths every pixel's `f64` `c` is the same number and a direct render is a flat
/// colour. A backend that cannot honour a non-null orbit must RETURN AN ERROR, not a shallow
/// image: the engine then logs and falls back to the CPU, which renders it deep and correct.
pub const IterFn = *const fn (
    view: SquareView,
    image_w: u32,
    image_h: u32,
    max_iter: u32,
    y0: u32,
    rows: u32,
    iter_band: []f32,
    orbit: ?*const perturb.ReferenceOrbit,
) anyerror!void;

/// The persistent render state + decoupling counters. The app allocates one via `init`,
/// drives it (`iterate` once, then `setViewport`/`setPolicy`/`resize` on navigation and
/// `setGradient`/`setMapping`/`setInterior` on palette edits), reads `output()` to upload,
/// and frees it via `deinit`.
///
/// Fields are public so the data/coordinate panels can read them; treat them as READ-ONLY
/// outside the methods below. In particular `max_iter` is DERIVED state — recomputed from
/// `policy` and `view` by every iteration path — so assigning it by hand only produces a
/// value the next pass overwrites.
pub const Engine = struct {
    alloc: std.mem.Allocator,
    /// The M3 view (T1's `SquareView`) the iteration buffer was computed for. Change it
    /// through `setViewport`, never in place, or the buffer and the view drift apart.
    view: SquareView,
    /// Width of the render image in pixels. For square renders, equals `image_side`.
    image_w: u32,
    /// Height of the render image in pixels. For square renders, equals `image_side`.
    image_h: u32,
    /// Navigation square side: `min(image_w, image_h)`. Used for zoom/pan geometry.
    /// Always > 0 for an engine built through `init`.
    image_side: u32,
    /// How `max_iter` is chosen (T3, plan A6). Change it through `setPolicy`.
    policy: IterPolicy,
    /// The iteration count the CURRENT buffer was computed with: `policy.effective` of the
    /// current view's magnification. Derived — see the struct doc.
    max_iter: u32,
    /// Persistent smooth-value buffer (one f32 per pixel, `S*S` long).
    iter: []f32,
    /// Packed RGBA8 output (4 bytes per pixel). Rewritten by every recolor.
    rgba: []u8,
    /// The current palette; mutated by `setGradient`, baked into `lut`.
    gradient: gradient.Gradient,
    /// The baked LUT for `gradient` (re-baked only when the gradient changes).
    lut: [gradient.lut_size]Rgba8,
    /// The current mapping selection; mutated by `setMapping`.
    params: mapping.Params,
    /// The dedicated interior color (plan A5); mutated by `setInterior`.
    interior: Rgba8,
    /// Number of iteration passes run. Bumped ONLY by `iterate`.
    iteration_passes: u32,
    /// Number of color passes run. Bumped by every recolor (iterate + each edit).
    color_passes: u32,
    /// When true and `gpu_iter_fn != null`, `iterate` dispatches via `gpu_iter_fn`
    /// instead of the built-in CPU path. Set by the UI toggle; wired by `main.zig`.
    use_gpu: bool,
    /// Optional GPU iteration function set by `main.zig` after pipeline creation.
    /// Null until wired; `iterate` falls back to CPU when null.
    gpu_iter_fn: ?IterFn,
    /// The in-flight progressive pass (M5), or null when the image is final. Non-null means
    /// rows `pass.rows_done ..` still show the seeded preview, so the UI must report
    /// "rendering" and freeze the edit panels. Owned by `beginPass`/`stepPass`; read it
    /// through `passFraction`.
    pass: ?progressive.Pass,
    /// This render's reference orbit (M6), or null when the current view is shallow or no band
    /// has needed it yet. Owned here: `ensureOrbit` allocates it, `releaseOrbit` frees it, and
    /// every render boundary releases — it is NEVER carried across renders. Read it through
    /// `orbitPtr`; treat as private.
    orbit: ?perturb.ReferenceOrbit,
    /// The centre `orbit` was computed for, and the `max_iter` it was computed to. `ensureOrbit`
    /// recomputes when either has moved, so an orbit left over from a superseded render can
    /// never colour a different image.
    orbit_center: viewport.ComplexHi,
    orbit_max_iter: u32,
    /// How many reference orbits this engine has computed. Bumped in the ONE place
    /// `perturb.ReferenceOrbit.compute` is called, so it IS the call count: a deep render must
    /// add exactly 1 however many chunks it took, and a shallow render must add 0.
    orbit_computations: u32,
    /// How many render-path summaries this engine has logged. Bumped in the ONE place
    /// `perturb.pathSummary` is called (`logPathSummary`), so it IS that call count: exactly
    /// one per completed render, one-shot or progressive.
    path_summaries: u32,

    /// Allocate the smooth-value + RGBA8 buffers for a square image of side `image_side`,
    /// derive `max_iter` from `policy` at `view`'s magnification, install the default
    /// gradient (baked) / linear mapping / opaque-black interior, and zero both counters.
    /// Does NOT iterate or recolor: after `init` both counters are 0 and the caller drives
    /// the first `iterate`. Both buffers are zeroed so a recolor before the first iteration
    /// is well-defined rather than reading undefined memory. Caller must `deinit`.
    ///
    /// Rejects a degenerate `view` or a zero `image_side` before allocating anything, and
    /// reports an allocation failure with the requested size. Caller must `deinit`.
    pub fn init(
        alloc: std.mem.Allocator,
        view: SquareView,
        image_side: u32,
        policy: IterPolicy,
    ) ResizeError!Engine {
        return initRect(alloc, view, image_side, image_side, policy);
    }

    /// Rectangular init. `image_side` = `min(w, h)` for navigation geometry.
    pub fn initRect(
        alloc: std.mem.Allocator,
        view: SquareView,
        w: u32,
        h: u32,
        policy: IterPolicy,
    ) ResizeError!Engine {
        const side = @min(w, h);
        try validateGeometry(view, side);
        const max_iter = try effectiveMaxIter(view, policy);
        const sizes = try bufferSizesRect(w, h);

        const iter = alloc.alloc(f32, sizes.pixels) catch |err| {
            logResizeFailure(side);
            return err;
        };
        errdefer alloc.free(iter);
        @memset(iter, 0.0);

        const rgba = alloc.alloc(u8, sizes.bytes) catch |err| {
            logResizeFailure(side);
            return err;
        };
        errdefer alloc.free(rgba);
        @memset(rgba, 0);

        const g = gradient.default();
        var engine = Engine{
            .alloc = alloc,
            .view = view,
            .image_w = w,
            .image_h = h,
            .image_side = side,
            .policy = policy,
            .max_iter = max_iter,
            .iter = iter,
            .rgba = rgba,
            .gradient = g,
            .lut = undefined,
            .params = .{},
            .interior = color.interior_color,
            .iteration_passes = 0,
            .color_passes = 0,
            .use_gpu = false,
            .gpu_iter_fn = null,
            .pass = null,
            .orbit = null,
            .orbit_center = .{ .re = 0, .im = 0 },
            .orbit_max_iter = 0,
            .orbit_computations = 0,
            .path_summaries = 0,
        };
        gradient.bakeLut(g, &engine.lut);
        return engine;
    }

    /// Free the owned buffers (and this render's reference orbit, if one is in flight — a
    /// `deinit` mid-pass must not leak it). Safe to call once after `init`.
    pub fn deinit(self: *Engine) void {
        self.releaseOrbit();
        self.alloc.free(self.iter);
        self.alloc.free(self.rgba);
    }

    // ─── M6: which iteration path, and the one orbit that serves it ───────────

    /// Whether the CURRENT view renders through the deep (perturbation) path: T3's
    /// `perturb.threshold_side` and below. THE decision — `iterate`, `stepPassRows` and the
    /// logged path summary all read it here, so they cannot disagree about which path ran.
    pub fn usesDeepPath(self: *const Engine) bool {
        return self.view.side <= perturb.threshold_side;
    }

    /// This render's reference orbit, computed on first use and then reused by every
    /// subsequent band of the same render; null when the view is shallow (nothing is
    /// allocated for a shallow render at all).
    ///
    /// The `f128` orbit loop is the single most expensive thing in a deep render, which is why
    /// it must happen once per render and not once per chunk — `orbit_computations` pins that.
    /// A failure is LOGGED with the depth and count that provoked it and RETURNED; the engine
    /// keeps its previous image and stays renderable.
    fn ensureOrbit(self: *Engine) IterateError!?*const perturb.ReferenceOrbit {
        if (!self.usesDeepPath()) {
            self.releaseOrbit();
            return null;
        }
        // Guard against an orbit left behind by a render whose inputs have since moved.
        if (self.orbit != null and (self.orbit_center.re != self.view.center_re or
            self.orbit_center.im != self.view.center_im or
            self.orbit_max_iter != self.max_iter))
        {
            self.releaseOrbit();
        }
        if (self.orbit == null) {
            const center = self.view.center();
            self.orbit = perturb.ReferenceOrbit.compute(self.alloc, center, self.max_iter) catch |err| {
                self.logOrbitFailure(err);
                return err;
            };
            self.orbit_center = center;
            self.orbit_max_iter = self.max_iter;
            self.orbit_computations += 1;
        }
        return self.orbitPtr();
    }

    /// Borrow this render's reference orbit, or null when there is none in flight. Read-only:
    /// the engine frees it at the next render boundary, so callers must not retain the pointer
    /// across `iterate` / `beginPass` / `cancelPass`.
    pub fn orbitPtr(self: *const Engine) ?*const perturb.ReferenceOrbit {
        if (self.orbit) |*o| return o;
        return null;
    }

    /// Free this render's reference orbit, if any. Idempotent. Called at every render boundary
    /// — including `cancelPass`, so abandoning a deep pass mid-flight hands the memory back
    /// immediately instead of holding `max_iter + 1` f64 pairs until the next render.
    fn releaseOrbit(self: *Engine) void {
        if (self.orbit) |*o| o.deinit(self.alloc);
        self.orbit = null;
        self.orbit_max_iter = 0;
    }

    /// Iterate rows `y0 .. y0+rows` of the persistent buffer ON THE CPU, through whichever
    /// path `orbit` selects. The ONE CPU dispatch site: `iterate`, `stepPassRows` and the GPU
    /// fallback all come here, so the one-shot and progressive renders are the same arithmetic.
    /// A band past the end of the buffer is a caller bug and returns `BufferSizeMismatch`
    /// rather than writing out of bounds.
    fn cpuIterateBand(
        self: *Engine,
        vp: Viewport,
        y0: u32,
        rows: u32,
        orbit: ?*const perturb.ReferenceOrbit,
    ) IterateError!void {
        const o = orbit orelse return iterbuf.iterateRowsInto(self.iter, vp, self.max_iter, y0, rows);
        const start: usize = @as(usize, y0) * @as(usize, self.image_w);
        const count: usize = @as(usize, rows) * @as(usize, self.image_w);
        if (start + count > self.iter.len) return EngineError.BufferSizeMismatch;
        // The deep path is band-LOCAL (row `y0` at index 0), like the GPU's contract.
        try iterbuf.iterateDeepBandInto(self.iter[start..][0..count], vp, self.max_iter, y0, rows, o);
    }

    /// (Re)run the EXPENSIVE stage for the current view / image side / policy: refresh
    /// `max_iter` from the policy, refill the smooth buffer via `iterbuf` (CPU) or
    /// `gpu_iter_fn` (GPU when `use_gpu` is true and the function is wired), then recolor
    /// and log the one-line pass summary. Bumps `iteration_passes` AND `color_passes`.
    /// This is the ONLY path that touches `iteration_passes`.
    pub fn iterate(self: *Engine) IterateError!void {
        // A one-shot pass supersedes any in-flight progressive pass for the old inputs — and
        // that pass's orbit with it, which is for a view this render may not share.
        self.pass = null;
        self.releaseOrbit();
        try validateGeometry(self.view, self.image_side);
        self.max_iter = try effectiveMaxIter(self.view, self.policy);
        const vp = self.renderViewport();
        // One orbit, for this render only: freed when the render ends, success or failure.
        const orbit = try self.ensureOrbit();
        defer self.releaseOrbit();
        if (self.use_gpu) {
            if (self.gpu_iter_fn) |iter_fn| {
                iter_fn(self.view, self.image_w, self.image_h, self.max_iter, 0, self.image_h, self.iter, orbit) catch |err| {
                    log.warn("GPU iterate failed ({s}), falling back to CPU", .{@errorName(err)});
                    try self.cpuIterateBand(vp, 0, self.image_h, orbit);
                };
            } else {
                try self.cpuIterateBand(vp, 0, self.image_h, orbit);
            }
        } else {
            try self.cpuIterateBand(vp, 0, self.image_h, orbit);
        }
        self.iteration_passes += 1;
        try self.recolor();
        self.logIteratePass();
    }

    /// Navigate: install a new view and re-iterate (+ recolor) for it. Bumps
    /// `iteration_passes` and `color_passes` by one each. A degenerate view is rejected and
    /// leaves the engine on the previous one, so a failed navigation never strands the
    /// buffer and the view out of sync.
    pub fn setViewport(self: *Engine, view: SquareView) IterateError!void {
        const previous = self.view;
        errdefer self.view = previous;
        self.view = view;
        try self.iterate();
    }

    /// Install a new view WITHOUT rendering it: refreshes `max_iter` for the new view and
    /// leaves the buffers showing the PREVIOUS view's image until the caller runs the next
    /// pass (`iterate`, `resizeRect`, or `beginPass` + `stepPass`). Bumps neither counter —
    /// nothing was rendered. A degenerate view is rejected and leaves the engine untouched.
    ///
    /// This is the seam the progressive path needs: `setViewport` re-iterates at the CURRENT
    /// resolution, and at full resolution that is exactly the blocking render M5 exists to
    /// avoid. The edge installs the view, then renders it coarse (cheap) or progressively.
    pub fn installView(self: *Engine, view: SquareView) IterateError!void {
        try validateGeometry(view, self.image_side);
        self.max_iter = try effectiveMaxIter(view, self.policy);
        self.view = view;
    }

    /// Install a new `max_iter` policy WITHOUT rendering it — the `setPolicy` counterpart of
    /// `installView`, with the same contract: `max_iter` is refreshed, the image is stale
    /// until the next pass, neither counter moves, and a policy the current magnification
    /// cannot satisfy is rejected with the previous one left in place.
    pub fn installPolicy(self: *Engine, policy: IterPolicy) IterateError!void {
        self.max_iter = try effectiveMaxIter(self.view, policy);
        self.policy = policy;
    }

    /// Install a new `max_iter` policy (T7's auto/manual control) and re-iterate: unlike the
    /// palette setters this DOES re-iterate, because `max_iter` feeds the iteration itself.
    /// A policy the current magnification cannot satisfy is rejected and leaves the engine on
    /// the previous policy. Re-iterates unconditionally — callers only set a policy that
    /// changed.
    pub fn setPolicy(self: *Engine, policy: IterPolicy) IterateError!void {
        const previous = self.policy;
        errdefer self.policy = previous;
        self.policy = policy;
        try self.iterate();
    }

    /// Resize the render square to `image_side` px (T5, on a window resize): reallocate both
    /// buffers when the pixel count changes, then re-iterate + recolor for the new side.
    /// Bumps both counters by one.
    ///
    /// Failure-atomic: a rejected side (0 px) or a failed allocation leaves the engine on its
    /// previous buffers and side — still renderable — and returns the error after logging the
    /// requested size. The new buffers are zeroed like `init`'s.
    pub fn resize(self: *Engine, image_side: u32) ResizeError!void {
        return self.resizeRect(image_side, image_side);
    }

    /// Resize to a rectangular render target. `image_side` = `min(w, h)` for nav geometry.
    pub fn resizeRect(self: *Engine, w: u32, h: u32) ResizeError!void {
        const side = @min(w, h);
        try validateGeometry(self.view, side);
        const sizes = try bufferSizesRect(w, h);

        if (sizes.pixels != self.iter.len) {
            const iter = self.alloc.alloc(f32, sizes.pixels) catch |err| {
                logResizeFailure(side);
                return err;
            };
            const rgba = self.alloc.alloc(u8, sizes.bytes) catch |err| {
                self.alloc.free(iter);
                logResizeFailure(side);
                return err;
            };
            @memset(iter, 0.0);
            @memset(rgba, 0);
            self.alloc.free(self.iter);
            self.alloc.free(self.rgba);
            self.iter = iter;
            self.rgba = rgba;
        }
        self.image_w = w;
        self.image_h = h;
        self.image_side = side;
        try self.iterate();
    }

    // ─── M5: the progressive (chunked) pass ──────────────────────────────────
    //
    // `iterate` refills the whole buffer in one call, which at full resolution blocks the
    // frame long enough to freeze the window. `beginPass` + repeated `stepPass` run that
    // SAME iteration in per-frame chunks, so the edge keeps drawing (and can show a
    // progress bar) while it runs. The finished buffer is scalar-identical to `iterate`'s
    // (pinned by a test below) and the counters move exactly once, at completion.

    /// Start a progressive pass at `w × h`, seeding the display with a BLOCKY PREVIEW.
    ///
    /// Refreshes `max_iter` from the policy, and when the dimensions changed, reallocates the
    /// buffers and fills the new smooth buffer with a nearest-neighbour upsample of the old
    /// one (`progressive.upsampleInto`) so the first frame of the pass shows a blocky version
    /// of the same view instead of black; the seeded image is coloured immediately. Then the
    /// caller drives `stepPass` once per frame until it returns true.
    ///
    /// Bumps NEITHER counter — the pass counts once, when its last chunk lands. Failure-atomic
    /// like `resizeRect`: a rejected geometry or a failed allocation leaves the engine on its
    /// previous buffers, dimensions and (cleared) pass state, still renderable.
    pub fn beginPass(self: *Engine, w: u32, h: u32) ResizeError!void {
        self.pass = null;
        // A new pass supersedes the previous render, orbit included: the first chunk that needs
        // one computes it for THIS view.
        self.releaseOrbit();
        const side = @min(w, h);
        try validateGeometry(self.view, side);
        self.max_iter = try effectiveMaxIter(self.view, self.policy);
        const sizes = try bufferSizesRect(w, h);

        if (w != self.image_w or h != self.image_h) {
            const iter = self.alloc.alloc(f32, sizes.pixels) catch |err| {
                logResizeFailure(side);
                return err;
            };
            const rgba = self.alloc.alloc(u8, sizes.bytes) catch |err| {
                self.alloc.free(iter);
                logResizeFailure(side);
                return err;
            };
            // Seed the preview. A failed upsample is not fatal — a black start still
            // renders correctly once the chunks land — so it degrades to a zero fill.
            progressive.upsampleInto(iter, w, h, self.iter, self.image_w, self.image_h) catch |err| {
                log.warn("preview upsample to {d}×{d} skipped ({s}); starting from black", .{ w, h, @errorName(err) });
                @memset(iter, 0.0);
            };
            @memset(rgba, 0);
            self.alloc.free(self.iter);
            self.alloc.free(self.rgba);
            self.iter = iter;
            self.rgba = rgba;
            self.image_w = w;
            self.image_h = h;
            self.image_side = side;
        }

        self.pass = .{ .rows_total = h };
        // Colour the seeded buffer so the preview is visible from the pass's first frame.
        // Not a counted color pass: the pass counts once, at completion.
        try self.recolorRows(0, h);
    }

    /// Run ONE time-budgeted chunk of the in-flight pass and return whether the pass is now
    /// complete (`true` also when no pass is in flight, i.e. the image is already final).
    /// Measures the chunk's wall-clock cost and re-times the next one through
    /// `progressive.Pass.advance`, so a chunk costs ~`progressive.target_chunk_ns` (500 ms)
    /// whatever the view, `max_iter` or machine. The clock affects only the CHUNK SIZE, never the
    /// values — `stepPassRows` is the deterministic path the tests drive.
    pub fn stepPass(self: *Engine) IterateError!bool {
        const p = self.pass orelse return true;
        const rows = p.nextChunk();
        var timer = std.time.Timer.start() catch null;
        const finished = try self.stepPassRows(rows);
        const elapsed: u64 = if (timer) |*t| t.read() else progressive.target_chunk_ns;
        if (self.pass) |*live| live.chunk_rows = progressive.adaptChunkRows(rows, elapsed, progressive.target_chunk_ns);
        return finished;
    }

    /// Iterate exactly `rows` more rows of the in-flight pass and colour them. Returns
    /// whether the pass completed; on completion bumps `iteration_passes` AND `color_passes`
    /// by one each, clears `pass`, and logs the same one-line summary as `iterate`.
    /// Deterministic (no clock): `stepPass` is the timed wrapper.
    ///
    /// GPU and CPU take the SAME shape here — one band per chunk. A GPU dispatch is per-band
    /// too (`IterFn` takes `y0`/`rows`), so a pinned `max_iter` in the millions progresses a
    /// band at a time instead of one dispatch long enough for the GPU watchdog to abort. A
    /// failed GPU band falls back to the CPU for THAT BAND only, so the fallback costs one
    /// chunk, not a whole frozen image.
    pub fn stepPassRows(self: *Engine, rows: u32) IterateError!bool {
        var p = self.pass orelse return true;
        try validateGeometry(self.view, self.image_side);
        const vp = self.renderViewport();
        // The SAME decision `iterate` makes, and the SAME orbit for every chunk of this pass:
        // the first chunk pays for the `f128` loop, the rest borrow it.
        const orbit = try self.ensureOrbit();

        const chunk = @min(rows, p.rows_total - @min(p.rows_done, p.rows_total));
        const y0 = p.rows_done;
        var done_on_gpu = false;
        if (self.use_gpu) {
            if (self.gpu_iter_fn) |iter_fn| {
                const band_start: usize = @as(usize, y0) * @as(usize, self.image_w);
                const band_len: usize = @as(usize, chunk) * @as(usize, self.image_w);
                if (band_start + band_len <= self.iter.len) {
                    const band = self.iter[band_start..][0..band_len];
                    if (iter_fn(self.view, self.image_w, self.image_h, self.max_iter, y0, chunk, band, orbit)) |_| {
                        done_on_gpu = true;
                    } else |err| {
                        log.warn("GPU iterate failed ({s}), falling back to CPU for rows {d}..{d}", .{
                            @errorName(err),
                            y0,
                            y0 + chunk,
                        });
                    }
                }
            }
        }
        if (!done_on_gpu) try self.cpuIterateBand(vp, y0, chunk, orbit);
        try self.recolorRows(y0, chunk);
        p.rows_done += chunk;
        self.pass = p;
        return self.finishPass();
    }

    /// Complete the pass if every row is in: count it once and clear the state.
    fn finishPass(self: *Engine) IterateError!bool {
        const p = self.pass orelse return true;
        if (!p.done()) return false;
        self.pass = null;
        self.iteration_passes += 1;
        self.color_passes += 1;
        self.logIteratePass();
        // The render is over: its orbit has no further reader.
        self.releaseOrbit();
        return true;
    }

    /// Abandon any in-flight progressive pass, leaving the partly refined image on display.
    /// The edge calls this when the user navigates again mid-pass: the new view starts its
    /// own pass, and the stale one must not write rows for the old inputs.
    ///
    /// Frees the abandoned pass's reference orbit too: navigating repeatedly during a deep zoom
    /// cancels a pass per input event, and an orbit held past its render would be an unbounded
    /// leak in exactly the interaction M6 exists for.
    pub fn cancelPass(self: *Engine) void {
        self.pass = null;
        self.releaseOrbit();
    }

    /// Completion of the in-flight pass in `[0, 1]` for the status bar, or null when the
    /// displayed image is final (nothing to report).
    pub fn passFraction(self: *const Engine) ?f32 {
        const p = self.pass orelse return null;
        return p.fraction();
    }

    /// Install a new palette, re-bake its LUT, and rerun ONLY the color pass. Bumps
    /// `color_passes`; leaves `iteration_passes` untouched (THE guarantee). Returns
    /// `EngineError.EmptyGradient` (before mutating any state) if `g` has no stops.
    pub fn setGradient(self: *Engine, g: gradient.Gradient) EngineError!void {
        if (g.count == 0) return EngineError.EmptyGradient;
        self.gradient = g;
        gradient.bakeLut(g, &self.lut);
        try self.recolor();
    }

    /// Install a new mapping selection and rerun ONLY the color pass. Bumps
    /// `color_passes`; leaves `iteration_passes` untouched (THE guarantee).
    pub fn setMapping(self: *Engine, params: mapping.Params) EngineError!void {
        self.params = params;
        try self.recolor();
    }

    /// Install a new interior color (plan A5) and rerun ONLY the color pass. Bumps
    /// `color_passes`; leaves `iteration_passes` untouched (THE guarantee).
    pub fn setInterior(self: *Engine, interior: Rgba8) EngineError!void {
        self.interior = interior;
        try self.recolor();
    }

    /// The cheap color pass: map the persistent smooth buffer through the current LUT +
    /// mapping + interior color into `rgba`. Bumps `color_passes`. Never re-iterates.
    fn recolor(self: *Engine) EngineError!void {
        try colorpass.colorInto(self.rgba, self.iter, &self.lut, self.max_iter, self.params, self.interior);
        self.color_passes += 1;
    }

    /// Colour image rows `y0 .. y0 + rows` only, by handing `colorpass.colorInto` the matching
    /// slices of the row-major buffers. Does NOT bump `color_passes`: this is a fragment of a
    /// pass, and a progressive pass counts once when its last chunk lands (see `finishPass`).
    /// A band that runs past the last row is a caller bug and surfaces as `BufferSizeMismatch`
    /// rather than an out-of-bounds write.
    fn recolorRows(self: *Engine, y0: u32, rows: u32) EngineError!void {
        const stride: usize = self.image_w;
        const start = @as(usize, y0) * stride;
        const count = @as(usize, rows) * stride;
        if (start + count > self.iter.len or (start + count) * 4 > self.rgba.len) {
            return EngineError.BufferSizeMismatch;
        }
        try colorpass.colorInto(
            self.rgba[start * 4 .. (start + count) * 4],
            self.iter[start .. start + count],
            &self.lut,
            self.max_iter,
            self.params,
            self.interior,
        );
    }

    /// Square image viewport (navigation geometry). Precondition: `image_side > 0`.
    pub fn imageViewport(self: *const Engine) Viewport {
        return self.view.imageViewport(self.image_side);
    }

    /// Actual render viewport — rectangular when w ≠ h. Used by iterate().
    pub fn renderViewport(self: *const Engine) Viewport {
        return self.view.rectViewport(self.image_w, self.image_h);
    }

    /// The current packed RGBA8 image for the app to upload/display (read-only view).
    pub fn output(self: *const Engine) []const u8 {
        return self.rgba;
    }

    /// Write this engine's recolor summary line into `buf` (see `colorPassSummary`).
    /// Convenience for the edge to log after a recolor; delegates to the pure free builder
    /// so the exact string has one definition.
    pub fn summary(self: *const Engine, buf: []u8) ![]u8 {
        return colorPassSummary(buf, self.color_passes, self.params.mode, self.gradient.count);
    }

    /// Write this engine's re-iterate summary line into `buf` (see `iteratePassSummary`).
    /// Pass a `[iterate_summary_buf_len]u8`.
    pub fn iterateSummary(self: *const Engine, buf: []u8) ![]u8 {
        return iteratePassSummary(buf, self.iteration_passes, self.view, self.image_side, self.policy);
    }

    /// Write WHICH iteration path this engine's current view uses into `buf` (T3's
    /// `perturb.pathSummary`, e.g. `"render path: deep (perturbation), side=1e-30"`). Pass a
    /// `[perturb.path_summary_buf_len]u8`. The depth and the path come from `usesDeepPath`, so
    /// the line can never advertise a path the render did not take.
    pub fn pathSummary(self: *const Engine, buf: []u8) ![]u8 {
        return perturb.pathSummary(buf, self.view.side, self.usesDeepPath());
    }

    /// Log the one-line summary of the pass that just completed. Thin by design: the string
    /// comes from the pure builder. A builder failure cannot be allowed to fail a successful
    /// render, so it degrades to a `.warn` naming the error instead of being swallowed.
    fn logIteratePass(self: *Engine) void {
        var buf: [iterate_summary_buf_len]u8 = undefined;
        if (self.iterateSummary(&buf)) |line| {
            log.info("{s}", .{line});
        } else |err| {
            log.warn(
                "iterate pass {d} completed but its summary could not be built ({s})",
                .{ self.iteration_passes, @errorName(err) },
            );
        }
        self.logPathSummary();
    }

    /// Log which path rendered the pass that just completed. The ONLY caller of
    /// `perturb.pathSummary` in the codebase, and it is called only from `logIteratePass` —
    /// i.e. exactly once per completed render, whether that render was one-shot or N chunks.
    /// `path_summaries` counts these, which is how the tests assert "once per render" by number.
    fn logPathSummary(self: *Engine) void {
        var buf: [perturb.path_summary_buf_len]u8 = undefined;
        if (self.pathSummary(&buf)) |line| {
            log.info("{s}", .{line});
        } else |err| {
            log.warn("render path summary could not be built ({s})", .{@errorName(err)});
        }
        self.path_summaries += 1;
    }

    /// Report a failed reference-orbit computation with the depth and iteration count that
    /// provoked it. `.err` + a typed error returned by the caller (see `emitErr` for why the
    /// emission is suppressed in the test tier).
    fn logOrbitFailure(self: *const Engine, err: anyerror) void {
        var buf: [orbit_message_buf_len]u8 = undefined;
        logFailure(orbitFailureMessage(&buf, err, self.view.side, self.max_iter));
    }
};

/// Buffer lengths for a square image: `pixels` f32 smooth values and `bytes` RGBA8 bytes.
const BufferSizes = struct { pixels: usize, bytes: usize };

/// The two buffer lengths for `image_side`, with the pixel count taken from M2's
/// `iterbuf.iterationBufferLen` (never re-derived). Requires an already-validated
/// `image_side > 0`. A side so absurd that its byte count does not fit `usize` is reported
/// as `OutOfMemory` with the requested size — a returned error, never an overflow panic.
fn bufferSizes(view: SquareView, image_side: u32) std.mem.Allocator.Error!BufferSizes {
    _ = view;
    return bufferSizesRect(image_side, image_side);
}

fn bufferSizesRect(w: u32, h: u32) std.mem.Allocator.Error!BufferSizes {
    const pixels = @as(usize, w) * @as(usize, h);
    const bytes = std.math.mul(usize, pixels, 4) catch {
        logResizeFailure(@min(w, h));
        return error.OutOfMemory;
    };
    return .{ .pixels = pixels, .bytes = bytes };
}

/// Reject a view or image side that cannot be rendered, logging the reason. The DECISION to
/// reject a view is entirely T1's (`SquareView.fromCenterSide`, the single validating
/// constructor); this only reports it.
fn validateGeometry(view: SquareView, image_side: u32) IterateError!void {
    _ = SquareView.fromCenterSide(view.center(), view.side) catch |err| {
        var buf: [viewport.message_buf_len]u8 = undefined;
        logFailure(degenerateViewMessage(&buf, view));
        return err;
    };
    if (image_side == 0) {
        var buf: [image_side_message_buf_len]u8 = undefined;
        logFailure(imageSideMessage(&buf, image_side));
        return EngineError.DegenerateImageSide;
    }
}

/// The `max_iter` this view deserves under `policy` — T3's `effective`, the single source of
/// truth, with the rejection logged in T3's own wording.
fn effectiveMaxIter(view: SquareView, policy: IterPolicy) autoiter.AutoIterError!u32 {
    const magnification = view.magnification();
    return policy.effective(magnification) catch |err| {
        switch (err) {
            error.InvalidMagnification => {
                var buf: [viewport.message_buf_len]u8 = undefined;
                logFailure(viewport.degenerateRegionMessage(&buf, "magnification", magnification));
            },
            error.MaxIterOutOfRange => {
                var buf: [autoiter.range_message_buf_len]u8 = undefined;
                logFailure(autoiter.maxIterRangeMessage(&buf, policy.manual_value));
            },
        }
        return err;
    };
}

/// Log a failed (re)allocation with the size that was asked for.
fn logResizeFailure(image_side: u32) void {
    var buf: [resize_message_buf_len]u8 = undefined;
    logFailure(resizeFailureMessage(&buf, image_side, requestedBytes(image_side)));
}

/// Log a pure builder's message at `.err`. The builder can only fail by running out of
/// buffer, which must not hide the failure being reported — hence the fallback line. The
/// message is built even when the emission is suppressed (see `emitErr`), so a mis-sized
/// call site is exercised by the tests that drive these failure paths.
fn logFailure(built: anyerror![]u8) void {
    if (built) |message| {
        emitErr("{s}", .{message});
    } else |err| {
        emitErr("engine failure message could not be built ({s})", .{@errorName(err)});
    }
}

/// `std.log.err` (scope `.fractal`) in the app — and deliberately a no-op in the FAST TEST
/// TIER: Zig 0.15's test runner counts every logged error as a test failure
/// (`lib/compiler/test_runner.zig`, `log_err_count` → `@panic("error logs detected")`), so a
/// module whose own tests drive its failure paths — which this one must, they are acceptance
/// criteria — can never be green while emitting `.err` from them. Nothing observable is lost:
/// the exact wording of every failure line is pinned by the builder tests below, the typed
/// error is asserted by the path tests, and `iterate`'s success summary (`.info`, which the
/// runner does not count) is emitted in both builds.
fn emitErr(comptime format: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    log.err(format, args);
}

/// Build the one-line recolor summary: `"color pass {n}: mode={s}, stops={k}"` where `n`
/// is the color-pass count, `s` is the mapping mode tag, and `k` is the gradient's stop
/// count. Pure (no I/O) so it is unit-tested for the exact string; the engine and the edge
/// pass it to `std.log`.
pub fn colorPassSummary(buf: []u8, color_passes: u32, mode: mapping.Mode, stops: usize) ![]u8 {
    return std.fmt.bufPrint(
        buf,
        "color pass {d}: mode={s}, stops={d}",
        .{ color_passes, @tagName(mode), stops },
    );
}

/// Digits in the widest `u32` (a pass counter or an image side).
const max_u32_digits: usize = std.fmt.comptimePrint("{d}", .{std.math.maxInt(u32)}).len;

/// Digits in the widest `u64` (a requested byte count).
const max_u64_digits: usize = std.fmt.comptimePrint("{d}", .{std.math.maxInt(u64)}).len;

const iterate_prefix = "iterate pass ";

/// Buffer size that fits ANY `iteratePassSummary` result. An UPPER bound rather than the
/// exact worst case, because `viewport.coord_buf_len` (the center readout) is itself a
/// bound; pinned by a test that the widest realistic line fits with room to spare. A
/// shorter buffer returns `error.NoSpaceLeft`.
pub const iterate_summary_buf_len: usize = iterate_prefix.len + max_u32_digits +
    ": center=".len + viewport.coord_buf_len +
    ", mag=".len + viewport.max_float_chars +
    ", ".len + autoiter.summary_buf_len +
    ", S=".len + max_u32_digits + "px".len;

/// The success summary for one iteration pass:
/// `"iterate pass 3: center=-0.7500 + 0.0000i, mag=2.0203050891044214e-1, max_iter=512 (auto), S=900px"`.
/// Pure (writes only into `buf`) so the exact wording is unit-tested without a window/GPU;
/// `Engine.iterate` passes it to `std.log.info`. Pass a `[iterate_summary_buf_len]u8`.
///
/// The `max_iter=... (auto|manual)` part is rendered by T3's `autoiter.policySummary` — the
/// one definition of that phrase, always via `IterPolicy.effective`. So the line reports the
/// CLAMPED count the pass actually iterated with (never a raw `manual_value`) and it
/// PROPAGATES an invalid magnification instead of logging a fabricated count. `mag` uses
/// `{e}` so a hostile magnitude stays a few characters, exactly like
/// `viewport.degenerateRegionMessage`; the center comes from T1's `formatCoord`, so it gains
/// decimals with zoom depth.
pub fn iteratePassSummary(
    buf: []u8,
    pass: u32,
    view: SquareView,
    image_side: u32,
    policy: IterPolicy,
) ![]u8 {
    const magnification = view.magnification();
    var policy_buf: [autoiter.summary_buf_len]u8 = undefined;
    const policy_part = try autoiter.policySummary(&policy_buf, policy, magnification);
    var center_buf: [viewport.coord_buf_len]u8 = undefined;
    const center_part = try viewport.formatCoord(&center_buf, view.center(), magnification);
    return std.fmt.bufPrint(
        buf,
        iterate_prefix ++ "{d}: center={s}, mag={e}, {s}, S={d}px",
        .{ pass, center_part, magnification, policy_part, image_side },
    );
}

/// The human-actionable message for a view the engine cannot render. Reuses T1's
/// `degenerateRegionMessage` so there is exactly ONE wording for a degenerate region; this
/// only names which number offended. Pass a `[viewport.message_buf_len]u8`.
pub fn degenerateViewMessage(buf: []u8, view: SquareView) ![]u8 {
    const field = degenerateField(view);
    return viewport.degenerateRegionMessage(buf, field.what, field.value);
}

/// Which number to name when T1 rejects a view. Only the MESSAGE depends on this: the
/// accept/reject decision is always `SquareView.fromCenterSide`'s, so the two cannot
/// disagree about whether a view is renderable.
/// The center is narrowed to `f64` for the message only: `degenerateRegionMessage` renders an
/// f64 with `{e}`, and the values that reach here are non-finite (they narrow exactly), so no
/// digit that matters is lost.
fn degenerateField(view: SquareView) struct { what: []const u8, value: f64 } {
    if (!std.math.isFinite(view.center_re)) return .{ .what = "center re", .value = @floatCast(view.center_re) };
    if (!std.math.isFinite(view.center_im)) return .{ .what = "center im", .value = @floatCast(view.center_im) };
    return .{ .what = "side", .value = view.side };
}

const image_side_prefix = "rejected image side: ";
const image_side_suffix = "px is not a renderable square; " ++
    "the render square needs at least 1px per side (a minimized window has none)";

/// Buffer size that fits ANY `imageSideMessage` result. Exactly the worst case, pinned by a
/// test; a shorter buffer returns `error.NoSpaceLeft`.
pub const image_side_message_buf_len: usize =
    image_side_prefix.len + max_u32_digits + image_side_suffix.len;

/// The human-actionable message for `EngineError.DegenerateImageSide`: the side that
/// arrived and what is needed instead. Pure so the wording is unit-tested once and reused by
/// every edge that reports it (T5's resize handler); pass a
/// `[image_side_message_buf_len]u8`.
pub fn imageSideMessage(buf: []u8, image_side: u32) ![]u8 {
    return std.fmt.bufPrint(buf, image_side_prefix ++ "{d}" ++ image_side_suffix, .{image_side});
}

const resize_prefix = "iteration buffer resize failed: ";
const resize_infix = "px square needs ";
const resize_suffix = " bytes; use a smaller window or free memory";

/// Buffer size that fits ANY `resizeFailureMessage` result. Exactly the worst case, pinned
/// by a test; a shorter buffer returns `error.NoSpaceLeft`.
pub const resize_message_buf_len: usize = resize_prefix.len + max_u32_digits + 1 +
    max_u32_digits + resize_infix.len + max_u64_digits + resize_suffix.len;

/// The human-actionable message for a failed buffer (re)allocation: the requested square,
/// what it costs, and the two ways out. Pure so the wording is unit-tested once; pass a
/// `[resize_message_buf_len]u8`.
pub fn resizeFailureMessage(buf: []u8, image_side: u32, bytes: u64) ![]u8 {
    return std.fmt.bufPrint(
        buf,
        resize_prefix ++ "{d}x{d}" ++ resize_infix ++ "{d}" ++ resize_suffix,
        .{ image_side, image_side, bytes },
    );
}

const orbit_prefix = "deep zoom reference orbit failed (";
const orbit_infix_side = ") at view side ";
const orbit_infix_iter = " with max_iter=";
const orbit_suffix = "; zoom out or lower max_iter — the previous image is still on screen";

/// Longest `@errorName` in `OrbitFailure`, taken FROM the error set so adding a failure mode
/// cannot silently overflow `orbit_message_buf_len`. Any other error reaching
/// `orbitFailureMessage` is truncated by the buffer, which surfaces as `NoSpaceLeft` and its
/// own logged line rather than a wrong message.
const max_orbit_error_name_len: usize = blk: {
    var longest: usize = 0;
    for (@typeInfo(OrbitFailure).error_set.?) |e| longest = @max(longest, e.name.len);
    break :blk longest;
};

/// Buffer size that fits ANY `orbitFailureMessage` result. Exactly the worst case, pinned by a
/// test; a shorter buffer returns `error.NoSpaceLeft`.
pub const orbit_message_buf_len: usize = orbit_prefix.len + max_orbit_error_name_len +
    orbit_infix_side.len + viewport.max_float_chars +
    orbit_infix_iter.len + max_u32_digits + orbit_suffix.len;

/// The human-actionable message for a reference orbit the engine could not compute: which
/// failure, how deep the view was, how many iterations it asked for, and the two ways out.
/// `side` uses `{e}` so a 1e-300 depth stays a few characters. Pure so the wording is
/// unit-tested once; pass a `[orbit_message_buf_len]u8`.
pub fn orbitFailureMessage(buf: []u8, err: anyerror, side: f64, max_iter: u32) ![]u8 {
    return std.fmt.bufPrint(
        buf,
        orbit_prefix ++ "{s}" ++ orbit_infix_side ++ "{e}" ++ orbit_infix_iter ++ "{d}" ++ orbit_suffix,
        .{ @errorName(err), side, max_iter },
    );
}

/// Bytes both buffers need for a square image of side `image_side`: 4 for the f32 smooth
/// value plus 4 for the RGBA8 texel, per pixel. `u64` and SATURATING, so reporting an
/// absurd requested size cannot overflow on the very path that reports a failure.
pub fn requestedBytes(image_side: u32) u64 {
    const side: u64 = image_side;
    return side *| side *| 8;
}

// ─── Tests ───────────────────────────────────────────────────────────────────
//
// The golden view: T1's `defaultView()` (the square containing the M0 region) rendered into
// a 64x64 image. An auto policy gives exactly `base_max_iter` (512) there, so the M2 golden
// numbers keep their meaning. The two key pixels below were verified against a render of
// that view.
const testing = std.testing;

const golden_side: u32 = 64;
const golden_pixels: usize = golden_side * golden_side;
/// What an auto policy resolves to at the golden view (T3's ramp floor).
const golden_iter: u32 = autoiter.base_max_iter;

// Verified against a render of the golden view:
//   * (40, 32) samples c ≈ (-0.285, -0.027) — deep inside the main cardioid ⇒ the interior
//     sentinel, so it tracks the interior color.
//   * (52, 29) samples c ≈ (0.371, 0.137) — a slow escape (smooth value ≈ 206) ⇒ colored
//     through the LUT.
const interior_px = .{ .x = 40, .y = 32 };
const exterior_px = .{ .x = 52, .y = 29 };

fn testView() SquareView {
    return SquareView.defaultView();
}

/// The golden view zoomed 8 doublings in (side / 256, so magnification is exactly 256x the
/// default): the auto ramp gives `base_max_iter + iter_per_doubling_squared · 8²` there.
fn zoomedView() viewport.ViewportError!SquareView {
    return SquareView.fromCenterSide(testView().center(), 3.5 / 256.0);
}

/// An engine on the golden view at the golden side with the default (auto) policy.
fn testEngine() !Engine {
    return Engine.init(testing.allocator, testView(), golden_side, .{});
}

/// A CPU-backed `IterFn` for the GPU-path tests: iterates the requested band into the
/// BAND-LOCAL buffer, which is exactly what `gpu/compute.zig`'s `gpuIterateRows` does. It
/// calls `iterbuf.iterateBandInto` rather than re-deriving the mapping, so these tests cannot
/// pass against a stub that disagrees with the real backends.
///
/// It models the M6 GPU backend as `main.zig` wires it today: a non-null orbit is REFUSED
/// (`error.DeepPathNotOnGpu`, T6's job), which is what makes the engine fall back to the CPU
/// and still render the view deep.
fn bandStub(
    view: SquareView,
    w: u32,
    h: u32,
    max_iter: u32,
    y0: u32,
    rows: u32,
    band: []f32,
    orbit: ?*const perturb.ReferenceOrbit,
) anyerror!void {
    if (orbit != null) return error.DeepPathNotOnGpu;
    try iterbuf.iterateBandInto(band, view.rectViewport(w, h), max_iter, y0, rows);
}

fn pixelAt(rgba: []const u8, x: usize, y: usize) Rgba8 {
    const base = (y * golden_side + x) * 4;
    return .{ rgba[base + 0], rgba[base + 1], rgba[base + 2], rgba[base + 3] };
}

/// A distinctive solid palette that shares no texel with the default gradient's exterior
/// colors, so a recolor to it is guaranteed to change exterior bytes.
fn solidGradient(c: Rgba8) gradient.Gradient {
    return gradient.Gradient.fromStops(&.{
        .{ .pos = 0.0, .color = c },
        .{ .pos = 1.0, .color = c },
    });
}

/// Count how many output bytes differ between two equal-length buffers.
fn diffCount(a: []const u8, b: []const u8) usize {
    var n: usize = 0;
    for (a, b) |x, y| {
        if (x != y) n += 1;
    }
    return n;
}

/// Count how many smooth values differ between two equal-length iteration buffers.
fn diffCountF32(a: []const f32, b: []const f32) usize {
    var n: usize = 0;
    for (a, b) |x, y| {
        if (x != y) n += 1;
    }
    return n;
}

// ─── M2 regression: init, the color pass, and THE GUARANTEE ──────────────────

test "init does not iterate or recolor: both counters start at zero" {
    var e = try testEngine();
    defer e.deinit();
    try testing.expectEqual(@as(u32, 0), e.iteration_passes);
    try testing.expectEqual(@as(u32, 0), e.color_passes);
}

test "init sizes the buffers to the square image side (rgba is 4x the smooth buffer)" {
    var e = try testEngine();
    defer e.deinit();
    try testing.expectEqual(golden_pixels, e.iter.len);
    try testing.expectEqual(e.iter.len * 4, e.rgba.len);
}

test "iterate: the first pass sets iteration_passes to exactly 1" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    try testing.expectEqual(@as(u32, 1), e.iteration_passes);
}

test "iterate: the whole output image is fully opaque (alpha 255)" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    var i: usize = 3;
    while (i < e.rgba.len) : (i += 4) try testing.expectEqual(@as(u8, 255), e.rgba[i]);
}

test "THE GUARANTEE: setGradient bumps color_passes but leaves iteration_passes unchanged" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    const iters_before = e.iteration_passes;
    const colors_before = e.color_passes;
    try e.setGradient(solidGradient(.{ 255, 0, 0, 255 }));
    try testing.expectEqual(iters_before, e.iteration_passes); // NEVER re-iterated
    try testing.expectEqual(colors_before + 1, e.color_passes); // recolored once
}

test "THE GUARANTEE: setMapping bumps color_passes but leaves iteration_passes unchanged" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    const iters_before = e.iteration_passes;
    const colors_before = e.color_passes;
    try e.setMapping(.{ .mode = .log });
    try testing.expectEqual(iters_before, e.iteration_passes); // NEVER re-iterated
    try testing.expectEqual(colors_before + 1, e.color_passes); // recolored once
}

test "setGradient changes at least one exterior pixel's bytes" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    var before: [golden_pixels * 4]u8 = undefined;
    @memcpy(&before, e.rgba);
    try e.setGradient(solidGradient(.{ 255, 0, 0, 255 }));
    // A gradient edit only touches exterior pixels (interior is colored outside the LUT),
    // so ANY differing byte is an exterior pixel changing.
    try testing.expect(diffCount(&before, e.rgba) > 0);
}

test "setGradient leaves interior pixels tracking the (unchanged) interior color" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    try e.setGradient(solidGradient(.{ 255, 0, 0, 255 }));
    // The known deep-interior pixel is colored outside the LUT, so it still equals the
    // engine's interior color after a palette edit.
    try testing.expectEqual(e.interior, pixelAt(e.rgba, interior_px.x, interior_px.y));
}

test "setMapping (linear -> log) changes exterior bytes with no iteration recompute" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate(); // default mapping is linear
    const iters_before = e.iteration_passes;
    var before: [golden_pixels * 4]u8 = undefined;
    @memcpy(&before, e.rgba);
    try e.setMapping(.{ .mode = .log });
    try testing.expect(diffCount(&before, e.rgba) > 0); // exterior recolored
    try testing.expectEqual(iters_before, e.iteration_passes); // no re-iteration
}

test "setInterior recolors interior pixels without re-iterating" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    const iters_before = e.iteration_passes;
    const colors_before = e.color_passes;
    const new_interior: Rgba8 = .{ 5, 10, 15, 255 };
    try e.setInterior(new_interior);
    try testing.expectEqual(new_interior, pixelAt(e.rgba, interior_px.x, interior_px.y));
    try testing.expectEqual(iters_before, e.iteration_passes); // no re-iteration
    try testing.expectEqual(colors_before + 1, e.color_passes);
}

test "the known exterior pixel escapes and is colored through the LUT, not the interior color" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    try e.setInterior(.{ 1, 2, 3, 255 });
    try testing.expect(!std.meta.eql(e.interior, pixelAt(e.rgba, exterior_px.x, exterior_px.y)));
}

test "output() returns the current RGBA8 buffer" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    try testing.expectEqual(e.rgba.ptr, e.output().ptr);
    try testing.expectEqual(e.rgba.len, e.output().len);
}

test "setGradient with an empty gradient returns EmptyGradient and does not recolor" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    const colors_before = e.color_passes;
    const empty = gradient.Gradient{}; // count == 0
    try testing.expectError(EngineError.EmptyGradient, e.setGradient(empty));
    try testing.expectEqual(colors_before, e.color_passes); // no recolor happened
}

test "a mis-sized internal buffer surfaces BufferSizeMismatch, not unreachable" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    // Shrink the output slice (same base pointer) so colorInto's size guard trips; a
    // recolor must RETURN the typed error rather than panicking. Restore before deinit so
    // the allocator frees the original allocation.
    const saved = e.rgba;
    e.rgba = saved[0 .. saved.len - 4];
    defer e.rgba = saved;
    try testing.expectError(EngineError.BufferSizeMismatch, e.setMapping(.{ .mode = .log }));
}

// ─── M3: navigation re-iterates, and the guarantee survives it ───────────────

test "setViewport bumps iteration_passes and color_passes by exactly one each" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    const iters_before = e.iteration_passes;
    const colors_before = e.color_passes;
    try e.setViewport(try zoomedView());
    try testing.expectEqual(iters_before + 1, e.iteration_passes);
    try testing.expectEqual(colors_before + 1, e.color_passes);
}

test "setViewport installs the new view and re-iterates the buffer for it" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    var shallow: [golden_pixels]f32 = undefined;
    @memcpy(&shallow, e.iter);

    const zoomed = try zoomedView();
    try e.setViewport(zoomed);
    try testing.expectEqual(zoomed, e.view);
    // The buffer really changed...
    try testing.expect(diffCountF32(&shallow, e.iter) > 0);
    // ...and it is exactly what an independent iteration of the NEW view produces.
    var expected: [golden_pixels]f32 = undefined;
    try iterbuf.iterateInto(&expected, zoomed.imageViewport(golden_side), e.max_iter);
    try testing.expectEqualSlices(f32, &expected, e.iter);
}

test "setViewport recolors the new iteration buffer (the output tracks the new view)" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    var before: [golden_pixels * 4]u8 = undefined;
    @memcpy(&before, e.rgba);
    try e.setViewport(try zoomedView());
    try testing.expect(diffCount(&before, e.rgba) > 0);
}

test "THE GUARANTEE under navigation: a gradient edit after a setViewport recolors only" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    try e.setViewport(try zoomedView());
    const iters_before = e.iteration_passes;
    const colors_before = e.color_passes;
    var iter_before: [golden_pixels]f32 = undefined;
    @memcpy(&iter_before, e.iter);

    try e.setGradient(solidGradient(.{ 0, 255, 0, 255 }));

    try testing.expectEqual(iters_before, e.iteration_passes); // NEVER re-iterated
    try testing.expectEqual(colors_before + 1, e.color_passes); // recolored once
    // Counters aside, the expensive buffer itself is untouched.
    try testing.expectEqualSlices(f32, &iter_before, e.iter);
}

test "THE GUARANTEE under navigation: a mapping edit after a setViewport recolors only" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    try e.setViewport(try zoomedView());
    const iters_before = e.iteration_passes;
    const colors_before = e.color_passes;
    var iter_before: [golden_pixels]f32 = undefined;
    @memcpy(&iter_before, e.iter);

    try e.setMapping(.{ .mode = .cyclic, .period = 16.0 });

    try testing.expectEqual(iters_before, e.iteration_passes);
    try testing.expectEqual(colors_before + 1, e.color_passes);
    try testing.expectEqualSlices(f32, &iter_before, e.iter);
}

test "the interleaved navigate/edit sequence has exactly the documented counter history" {
    var e = try testEngine();
    defer e.deinit();
    // Only the four iteration paths bump iteration_passes; every step bumps color_passes.
    try e.iterate();
    try testing.expectEqual([2]u32{ 1, 1 }, [2]u32{ e.iteration_passes, e.color_passes });
    try e.setViewport(try zoomedView());
    try testing.expectEqual([2]u32{ 2, 2 }, [2]u32{ e.iteration_passes, e.color_passes });
    try e.setGradient(solidGradient(.{ 9, 9, 9, 255 }));
    try testing.expectEqual([2]u32{ 2, 3 }, [2]u32{ e.iteration_passes, e.color_passes });
    try e.setMapping(.{ .mode = .log });
    try testing.expectEqual([2]u32{ 2, 4 }, [2]u32{ e.iteration_passes, e.color_passes });
    try e.setInterior(.{ 0, 0, 0, 255 });
    try testing.expectEqual([2]u32{ 2, 5 }, [2]u32{ e.iteration_passes, e.color_passes });
    try e.setPolicy(try IterPolicy.manual(64));
    try testing.expectEqual([2]u32{ 3, 6 }, [2]u32{ e.iteration_passes, e.color_passes });
    try e.resize(32);
    try testing.expectEqual([2]u32{ 4, 7 }, [2]u32{ e.iteration_passes, e.color_passes });
    try e.setGradient(solidGradient(.{ 7, 7, 7, 255 }));
    try testing.expectEqual([2]u32{ 4, 8 }, [2]u32{ e.iteration_passes, e.color_passes });
}

test "a degenerate view is rejected: the engine keeps its view and does not re-iterate" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    const iters_before = e.iteration_passes;
    const zero_side = SquareView{ .center_re = -0.75, .center_im = 0.0, .side = 0.0 };
    try testing.expectError(viewport.ViewportError.DegenerateRegion, e.setViewport(zero_side));
    try testing.expectEqual(testView(), e.view);
    try testing.expectEqual(iters_before, e.iteration_passes);
}

test "a view whose magnification overflows the auto ramp is rejected, not rendered" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    // A subnormal side is a finite positive extent (T1 accepts it) but 1/(side*sqrt2)
    // overflows to inf, which the auto ramp cannot use.
    const subnormal = try SquareView.fromCenterSide(testView().center(), std.math.floatTrueMin(f64));
    try testing.expectError(autoiter.AutoIterError.InvalidMagnification, e.setViewport(subnormal));
    try testing.expectEqual(testView(), e.view);
    try testing.expectEqual(@as(u32, 1), e.iteration_passes);
}

// ─── M3: max_iter comes from the policy, once ────────────────────────────────

test "init derives max_iter from an auto policy at the view's magnification" {
    var e = try testEngine();
    defer e.deinit();
    try testing.expectEqual(golden_iter, e.max_iter);
}

test "init derives max_iter from a manual policy, ignoring the ramp" {
    var e = try Engine.init(testing.allocator, testView(), golden_side, try IterPolicy.manual(300));
    defer e.deinit();
    try testing.expectEqual(@as(u32, 300), e.max_iter);
}

test "setViewport refreshes max_iter from the auto ramp for the new magnification" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    try e.setViewport(try zoomedView());
    // 8 doublings in, from the ramp's own coefficient rather than a literal: base_max_iter +
    // k·8². Spelled out here (not by calling `autoMaxIter`) so this still asserts the engine
    // installed the RAMP's count and not some other number it happened to compute.
    try testing.expectEqual(
        autoiter.base_max_iter +
            @as(u32, @intFromFloat(@round(autoiter.iter_per_doubling_squared * 64.0))),
        e.max_iter,
    );
}

test "setPolicy re-iterates with the new effective max_iter" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    const iters_before = e.iteration_passes;

    try e.setPolicy(try IterPolicy.manual(64));

    try testing.expectEqual(iters_before + 1, e.iteration_passes);
    try testing.expectEqual(@as(u32, 64), e.max_iter);
    // The buffer is the one a 64-iteration render of the same view produces.
    var expected: [golden_pixels]f32 = undefined;
    try iterbuf.iterateInto(&expected, testView().imageViewport(golden_side), 64);
    try testing.expectEqualSlices(f32, &expected, e.iter);
}

test "setPolicy clamps a hand-built out-of-range manual value instead of rendering it" {
    // Deliberately a 1×1 view far OUTSIDE the set: the clamped count is 2^24, and this test
    // asserts the count, not the pixels — every pixel here escapes on the first iteration, so
    // the assertion stays free instead of running 16.7M iterations per pixel.
    const escapes_at_once = try SquareView.fromCenterSide(.{ .re = 10.0, .im = 10.0 }, 1.0e-3);
    var e = try Engine.init(testing.allocator, escapes_at_once, 1, .{});
    defer e.deinit();
    try e.iterate();
    try e.setPolicy(.{ .auto = false, .manual_value = std.math.maxInt(u32) });
    try testing.expectEqual(autoiter.max_manual_iter, e.max_iter);
}

test "a policy the current magnification cannot satisfy leaves the previous policy in place" {
    const subnormal = try SquareView.fromCenterSide(testView().center(), std.math.floatTrueMin(f64));
    const pinned = try IterPolicy.manual(32);
    var e = try Engine.init(testing.allocator, subnormal, golden_side, pinned);
    defer e.deinit();
    try e.iterate();
    // Switching this view to the auto ramp cannot work: its magnification is inf.
    try testing.expectError(autoiter.AutoIterError.InvalidMagnification, e.setPolicy(.{}));
    try testing.expectEqual(pinned, e.policy);
    try testing.expectEqual(@as(u32, 32), e.max_iter);
}

test "init rejects an auto policy on a view whose magnification is unusable" {
    const subnormal = try SquareView.fromCenterSide(testView().center(), std.math.floatTrueMin(f64));
    try testing.expectError(
        autoiter.AutoIterError.InvalidMagnification,
        Engine.init(testing.allocator, subnormal, golden_side, .{}),
    );
}

// ─── M3: resize ──────────────────────────────────────────────────────────────

test "resize changes both buffer lengths to the new square side" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    const new_side: u32 = 96;
    try e.resize(new_side);
    try testing.expectEqual(@as(usize, new_side) * new_side, e.iter.len);
    try testing.expectEqual(e.iter.len * 4, e.rgba.len);
    try testing.expectEqual(new_side, e.image_side);
}

test "resize re-iterates at the new side, matching an independent iteration" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    const new_side: u32 = 32;
    try e.resize(new_side);

    const expected = try testing.allocator.alloc(f32, @as(usize, new_side) * new_side);
    defer testing.allocator.free(expected);
    try iterbuf.iterateInto(expected, testView().imageViewport(new_side), e.max_iter);
    try testing.expectEqualSlices(f32, expected, e.iter);
}

test "resize bumps iteration_passes and color_passes by exactly one each" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    try e.resize(48);
    try testing.expectEqual(@as(u32, 2), e.iteration_passes);
    try testing.expectEqual(@as(u32, 2), e.color_passes);
}

test "the color pass after a resize fills exactly S*S opaque RGBA texels" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    const new_side: u32 = 17; // odd, so a stale stride would misalign
    try e.resize(new_side);
    try testing.expectEqual(@as(usize, new_side) * new_side * 4, e.rgba.len);
    var i: usize = 3;
    var texels: usize = 0;
    while (i < e.rgba.len) : (i += 4) {
        try testing.expectEqual(@as(u8, 255), e.rgba[i]);
        texels += 1;
    }
    try testing.expectEqual(@as(usize, new_side) * new_side, texels);
}

test "resize to the same side keeps the buffers and still re-iterates" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    const len_before = e.iter.len;
    try e.resize(golden_side);
    try testing.expectEqual(len_before, e.iter.len);
    try testing.expectEqual(@as(u32, 2), e.iteration_passes);
}

test "resize(0) returns DegenerateImageSide and leaves the engine renderable" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    try testing.expectError(EngineError.DegenerateImageSide, e.resize(0));
    try testing.expectEqual(golden_side, e.image_side);
    try testing.expectEqual(golden_pixels, e.iter.len);
    try testing.expectEqual(@as(u32, 1), e.iteration_passes);
}

test "init(0) rejects a zero image side before allocating anything" {
    try testing.expectError(
        EngineError.DegenerateImageSide,
        Engine.init(testing.allocator, testView(), 0, .{}),
    );
}

test "a resize whose smooth-buffer allocation fails keeps the previous buffers" {
    // init performs exactly two allocations, so index 2 is the resize's first one.
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2 });
    var e = try Engine.init(failing.allocator(), testView(), golden_side, .{});
    defer e.deinit();
    try e.iterate();
    try testing.expectError(error.OutOfMemory, e.resize(128));
    try testing.expectEqual(golden_side, e.image_side);
    try testing.expectEqual(golden_pixels, e.iter.len);
    try testing.expectEqual(golden_pixels * 4, e.rgba.len);
    try testing.expectEqual(@as(u32, 1), e.iteration_passes);
}

test "a resize whose RGBA allocation fails frees the smooth buffer it already took" {
    // Index 3 is the resize's SECOND allocation; the first must be released or the
    // testing allocator reports a leak when this test ends.
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 3 });
    var e = try Engine.init(failing.allocator(), testView(), golden_side, .{});
    defer e.deinit();
    try e.iterate();
    try testing.expectError(error.OutOfMemory, e.resize(128));
    try testing.expectEqual(golden_pixels, e.iter.len);
}

test "resize keeps the palette state, so the next color pass uses the edited gradient" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    const solid: Rgba8 = .{ 200, 100, 50, 255 };
    try e.setGradient(solidGradient(solid));
    try e.setInterior(.{ 0, 0, 0, 255 });
    try e.resize(32);
    // Every texel is either the solid palette color or the interior color.
    var i: usize = 0;
    while (i < e.rgba.len) : (i += 4) {
        const texel: Rgba8 = .{ e.rgba[i], e.rgba[i + 1], e.rgba[i + 2], e.rgba[i + 3] };
        try testing.expect(std.meta.eql(texel, solid) or std.meta.eql(texel, e.interior));
    }
}

// ─── M5: the progressive (chunked) pass ──────────────────────────────────────

/// Drive an in-flight pass to completion in fixed-size chunks (deterministic: no clock).
fn drainPass(e: *Engine, chunk: u32) !void {
    while (!(try e.stepPassRows(chunk))) {}
}

test "beginPass bumps neither counter: the pass counts only when it completes" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    try e.beginPass(golden_side, golden_side);
    try testing.expectEqual(@as(u32, 1), e.iteration_passes);
}

test "beginPass opens a pass covering every image row" {
    var e = try testEngine();
    defer e.deinit();
    try e.beginPass(golden_side, golden_side);
    try testing.expectEqual(@as(u32, golden_side), e.pass.?.rows_total);
}

test "a progressive pass in chunks produces the same buffer as the one-shot iterate" {
    // THE guarantee the whole feature rests on: chunking is invisible in the output.
    var chunked = try testEngine();
    defer chunked.deinit();
    try chunked.beginPass(golden_side, golden_side);
    try drainPass(&chunked, 7); // 7 does not divide 64 — the last chunk is short

    var one_shot = try testEngine();
    defer one_shot.deinit();
    try one_shot.iterate();

    try testing.expectEqualSlices(f32, one_shot.iter, chunked.iter);
}

test "a completed progressive pass recolors every pixel the one-shot pass would" {
    var chunked = try testEngine();
    defer chunked.deinit();
    try chunked.beginPass(golden_side, golden_side);
    try drainPass(&chunked, 5);

    var one_shot = try testEngine();
    defer one_shot.deinit();
    try one_shot.iterate();

    try testing.expectEqual(@as(usize, 0), diffCount(one_shot.rgba, chunked.rgba));
}

test "a completed progressive pass bumps iteration_passes by exactly one" {
    var e = try testEngine();
    defer e.deinit();
    try e.beginPass(golden_side, golden_side);
    try drainPass(&e, 9);
    try testing.expectEqual(@as(u32, 1), e.iteration_passes);
}

test "a completed progressive pass bumps color_passes by exactly one" {
    // Every chunk recolors its own band, but the pass is ONE color pass.
    var e = try testEngine();
    defer e.deinit();
    try e.beginPass(golden_side, golden_side);
    try drainPass(&e, 9);
    try testing.expectEqual(@as(u32, 1), e.color_passes);
}

test "a completed progressive pass clears the pass state" {
    var e = try testEngine();
    defer e.deinit();
    try e.beginPass(golden_side, golden_side);
    try drainPass(&e, 64);
    try testing.expectEqual(@as(?f32, null), e.passFraction());
}

test "passFraction reports the completed row ratio mid-pass" {
    var e = try testEngine();
    defer e.deinit();
    try e.beginPass(golden_side, golden_side);
    _ = try e.stepPassRows(golden_side / 4);
    try testing.expectEqual(@as(?f32, 0.25), e.passFraction());
}

test "beginPass seeds the new buffer with a blocky preview of the previous image" {
    var e = try Engine.initRect(testing.allocator, testView(), 2, 2, .{});
    defer e.deinit();
    try e.iterate();
    const top_left = e.iter[0];
    try e.beginPass(4, 4);
    // Before any chunk runs, source pixel (0,0) already fills the destination's 2×2 block,
    // so dst (1,1) — index 5 — holds it.
    try testing.expectEqual(top_left, e.iter[5]);
}

test "beginPass resizes the buffers to the new dimensions" {
    var e = try testEngine();
    defer e.deinit();
    try e.beginPass(golden_side * 2, golden_side);
    try testing.expectEqual(@as(usize, golden_side * 2 * golden_side), e.iter.len);
}

test "a progressive pass at a new size matches an independent iterate at that size" {
    var chunked = try testEngine();
    defer chunked.deinit();
    try chunked.iterate();
    try chunked.beginPass(golden_side, golden_side / 2);
    try drainPass(&chunked, 3);

    var direct = try Engine.initRect(testing.allocator, testView(), golden_side, golden_side / 2, .{});
    defer direct.deinit();
    try direct.iterate();

    try testing.expectEqualSlices(f32, direct.iter, chunked.iter);
}

test "cancelPass abandons the pass, leaving the partly refined image on display" {
    var e = try testEngine();
    defer e.deinit();
    try e.beginPass(golden_side, golden_side);
    _ = try e.stepPassRows(4);
    e.cancelPass();
    try testing.expectEqual(@as(?f32, null), e.passFraction());
}

test "a one-shot iterate supersedes an in-flight progressive pass" {
    var e = try testEngine();
    defer e.deinit();
    try e.beginPass(golden_side, golden_side);
    _ = try e.stepPassRows(4);
    try e.iterate();
    try testing.expectEqual(@as(?f32, null), e.passFraction());
}

test "beginPass(0, 0) returns DegenerateImageSide and leaves the engine renderable" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    try testing.expectError(EngineError.DegenerateImageSide, e.beginPass(0, 0));
    try testing.expectEqual(golden_pixels, e.iter.len);
}

test "installView moves neither counter: nothing is rendered" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    try e.installView(try zoomedView());
    try testing.expectEqual([2]u32{ 1, 1 }, [2]u32{ e.iteration_passes, e.color_passes });
}

test "installView leaves the previous view's pixels on display until the next pass" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    const before = try testing.allocator.dupe(f32, e.iter);
    defer testing.allocator.free(before);
    try e.installView(try zoomedView());
    try testing.expectEqualSlices(f32, before, e.iter);
}

test "installView refreshes max_iter for the new view's magnification" {
    var e = try testEngine();
    defer e.deinit();
    const before = e.max_iter;
    try e.installView(try zoomedView());
    try testing.expect(e.max_iter != before);
}

test "installView then iterate matches setViewport exactly" {
    var a = try testEngine();
    defer a.deinit();
    var b = try testEngine();
    defer b.deinit();
    try a.setViewport(try zoomedView());
    try b.installView(try zoomedView());
    try b.iterate();
    try testing.expectEqualSlices(f32, a.iter, b.iter);
}

test "installView rejects a degenerate view and keeps the previous one" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    const zero_side = SquareView{ .center_re = -0.75, .center_im = 0.0, .side = 0.0 };
    try testing.expectError(viewport.ViewportError.DegenerateRegion, e.installView(zero_side));
    try testing.expectEqual(testView(), e.view);
}

test "installPolicy moves neither counter and refreshes max_iter" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    try e.installPolicy(try IterPolicy.manual(77));
    try testing.expectEqual(@as(u32, 77), e.max_iter);
    try testing.expectEqual([2]u32{ 1, 1 }, [2]u32{ e.iteration_passes, e.color_passes });
}

test "installPolicy rejects a policy the current magnification cannot satisfy" {
    const subnormal = try SquareView.fromCenterSide(testView().center(), std.math.floatTrueMin(f64));
    const pinned = try IterPolicy.manual(32);
    var e = try Engine.init(testing.allocator, subnormal, golden_side, pinned);
    defer e.deinit();
    try testing.expectError(autoiter.AutoIterError.InvalidMagnification, e.installPolicy(.{}));
    try testing.expectEqual(pinned, e.policy);
}

test "THE GUARANTEE mid-pass: a palette edit during a pass recolors without re-iterating" {
    var e = try testEngine();
    defer e.deinit();
    try e.beginPass(golden_side, golden_side);
    _ = try e.stepPassRows(8);
    const before = e.iteration_passes;
    try e.setGradient(solidGradient(.{ 9, 9, 9, 255 }));
    try testing.expectEqual(before, e.iteration_passes);
}

// ─── M3: the pure summary + message builders ─────────────────────────────────

test "iteratePassSummary produces the documented one-line re-iterate summary" {
    var buf: [iterate_summary_buf_len]u8 = undefined;
    const line = try iteratePassSummary(&buf, 3, testView(), 900, .{});
    try testing.expectEqualStrings(
        "iterate pass 3: center=-0.7500 + 0.0000i, mag=2.0203050891044214e-1, " ++
            "max_iter=512 (auto), S=900px",
        line,
    );
}

test "iteratePassSummary annotates a pinned max_iter as manual and gains center decimals" {
    var buf: [iterate_summary_buf_len]u8 = undefined;
    const line = try iteratePassSummary(&buf, 2, try zoomedView(), golden_side, try IterPolicy.manual(300));
    try testing.expectEqualStrings(
        "iterate pass 2: center=-0.750000 + 0.000000i, mag=5.171981028107319e1, " ++
            "max_iter=300 (manual), S=64px",
        line,
    );
}

test "iteratePassSummary reports the clamped effective max_iter, not a raw manual_value" {
    // Guards the one-source-of-truth premise: a line formatted from `manual_value` would
    // advertise 99999999 while the render used 16777216. Both have 8 digits, so the claim is
    // about the value and cannot be satisfied by a buffer-length accident.
    var buf: [iterate_summary_buf_len]u8 = undefined;
    const line = try iteratePassSummary(&buf, 1, testView(), golden_side, .{ .auto = false, .manual_value = 99_999_999 });
    try testing.expectEqualStrings(
        "iterate pass 1: center=-0.7500 + 0.0000i, mag=2.0203050891044214e-1, " ++
            "max_iter=16777216 (manual), S=64px",
        line,
    );
}

test "iteratePassSummary propagates an invalid magnification instead of fabricating a count" {
    var buf: [iterate_summary_buf_len]u8 = undefined;
    const subnormal = try SquareView.fromCenterSide(testView().center(), std.math.floatTrueMin(f64));
    try testing.expectError(
        autoiter.AutoIterError.InvalidMagnification,
        iteratePassSummary(&buf, 1, subnormal, golden_side, .{}),
    );
}

test "iteratePassSummary reports NoSpaceLeft instead of truncating" {
    var buf: [iterate_prefix.len]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, iteratePassSummary(&buf, 1, testView(), 900, .{}));
}

test "iterate_summary_buf_len fits the widest line the engine can log" {
    // Every field at its maximum: a saturated pass counter, a deep off-center view (17
    // decimals per part), a capped max_iter and a saturated image side.
    var buf: [iterate_summary_buf_len]u8 = undefined;
    const deep = try SquareView.fromCenterSide(.{ .re = -1.2345678901234567, .im = -0.9876543210987654 }, 1.0e-13);
    const line = try iteratePassSummary(&buf, std.math.maxInt(u32), deep, std.math.maxInt(u32), .{});
    try testing.expect(line.len <= iterate_summary_buf_len);
}

test "Engine.iterateSummary reflects the live pass counter, view, side and policy" {
    var e = try Engine.init(testing.allocator, testView(), golden_side, try IterPolicy.manual(300));
    defer e.deinit();
    try e.iterate();
    try e.setViewport(try zoomedView());
    var buf: [iterate_summary_buf_len]u8 = undefined;
    try testing.expectEqualStrings(
        "iterate pass 2: center=-0.750000 + 0.000000i, mag=5.171981028107319e1, " ++
            "max_iter=300 (manual), S=64px",
        try e.iterateSummary(&buf),
    );
}

test "the logged max_iter is exactly the count the engine iterated with" {
    // The anti-bypass check: whatever the engine rendered with must be the number in the
    // line, including when the policy needed clamping.
    var e = try Engine.init(testing.allocator, testView(), golden_side, .{ .auto = false, .manual_value = 5000 });
    defer e.deinit();
    try e.iterate();
    var buf: [iterate_summary_buf_len]u8 = undefined;
    const line = try e.iterateSummary(&buf);
    var needle_buf: [autoiter.summary_buf_len]u8 = undefined;
    const needle = try std.fmt.bufPrint(&needle_buf, "max_iter={d} (manual)", .{e.max_iter});
    try testing.expect(std.mem.indexOf(u8, line, needle) != null);
}

test "colorPassSummary produces the documented one-line string" {
    var buf: [64]u8 = undefined;
    const line = try colorPassSummary(&buf, 2, .log, 5);
    try testing.expectEqualStrings("color pass 2: mode=log, stops=5", line);
}

test "Engine.summary reflects the live counter, mapping mode, and stop count" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate(); // color_passes -> 1, default 5-stop palette, linear
    var buf: [64]u8 = undefined;
    const line = try e.summary(&buf);
    try testing.expectEqualStrings("color pass 1: mode=linear, stops=5", line);
}

test "degenerateViewMessage names the offending side in T1's wording" {
    var buf: [viewport.message_buf_len]u8 = undefined;
    const view = SquareView{ .center_re = -0.75, .center_im = 0.0, .side = 0.0 };
    try testing.expectEqualStrings(
        "rejected viewport: side=0e0 is not a finite positive extent; " ++
            "enter a positive magnification or two distinct corners",
        try degenerateViewMessage(&buf, view),
    );
}

test "degenerateViewMessage names a non-finite center instead of the side" {
    var buf: [viewport.message_buf_len]u8 = undefined;
    const view = SquareView{ .center_re = -0.75, .center_im = std.math.inf(f64), .side = 3.5 };
    try testing.expectEqualStrings(
        "rejected viewport: center im=inf is not a finite positive extent; " ++
            "enter a positive magnification or two distinct corners",
        try degenerateViewMessage(&buf, view),
    );
}

test "imageSideMessage names the rejected pixel side and what is needed" {
    var buf: [image_side_message_buf_len]u8 = undefined;
    try testing.expectEqualStrings(
        "rejected image side: 0px is not a renderable square; the render square needs " ++
            "at least 1px per side (a minimized window has none)",
        try imageSideMessage(&buf, 0),
    );
}

test "image_side_message_buf_len is exactly the worst-case message length" {
    var buf: [image_side_message_buf_len]u8 = undefined;
    const message = try imageSideMessage(&buf, std.math.maxInt(u32));
    try testing.expectEqual(image_side_message_buf_len, message.len);
}

test "resizeFailureMessage names the requested square, its cost and the ways out" {
    var buf: [resize_message_buf_len]u8 = undefined;
    try testing.expectEqualStrings(
        "iteration buffer resize failed: 4096x4096px square needs 134217728 bytes; " ++
            "use a smaller window or free memory",
        try resizeFailureMessage(&buf, 4096, requestedBytes(4096)),
    );
}

test "resize_message_buf_len is exactly the worst-case message length" {
    var buf: [resize_message_buf_len]u8 = undefined;
    const side = std.math.maxInt(u32);
    const message = try resizeFailureMessage(&buf, side, std.math.maxInt(u64));
    try testing.expectEqual(resize_message_buf_len, message.len);
}

test "requestedBytes counts 8 bytes per pixel (one f32 plus one RGBA8 texel)" {
    try testing.expectEqual(@as(u64, 64 * 64 * 8), requestedBytes(64));
    try testing.expectEqual(@as(u64, 0), requestedBytes(0));
}

test "requestedBytes saturates instead of overflowing for an absurd side" {
    try testing.expectEqual(std.math.maxInt(u64), requestedBytes(std.math.maxInt(u32)));
}

// ─── M4: GPU toggle routing ───────────────────────────────────────────────────

test "use_gpu=false with no gpu_iter_fn: CPU path runs, iteration_passes increments" {
    var e = try testEngine();
    defer e.deinit();
    e.use_gpu = false;
    e.gpu_iter_fn = null;
    try e.iterate();
    try testing.expectEqual(@as(u32, 1), e.iteration_passes);
}

test "use_gpu=true with no gpu_iter_fn: CPU fallback runs, iteration_passes increments" {
    var e = try testEngine();
    defer e.deinit();
    e.use_gpu = true;
    e.gpu_iter_fn = null;
    try e.iterate();
    try testing.expectEqual(@as(u32, 1), e.iteration_passes);
}

test "use_gpu=true with a gpu_iter_fn: the fn is called, iteration_passes increments" {
    const stub = struct {
        fn call(
            view: SquareView,
            w: u32,
            h: u32,
            max_iter: u32,
            y0: u32,
            rows: u32,
            band: []f32,
            orbit: ?*const perturb.ReferenceOrbit,
        ) anyerror!void {
            try bandStub(view, w, h, max_iter, y0, rows, band, orbit);
        }
    }.call;

    var e = try testEngine();
    defer e.deinit();
    e.use_gpu = true;
    e.gpu_iter_fn = stub;
    try e.iterate();
    try testing.expectEqual(@as(u32, 1), e.iteration_passes);
    // color_passes also incremented (recolor runs after iterate).
    try testing.expectEqual(@as(u32, 1), e.color_passes);
}

test "THE GUARANTEE holds with GPU path: setGradient after GPU iterate does not re-iterate" {
    const stub = struct {
        fn call(
            view: SquareView,
            w: u32,
            h: u32,
            max_iter: u32,
            y0: u32,
            rows: u32,
            band: []f32,
            orbit: ?*const perturb.ReferenceOrbit,
        ) anyerror!void {
            try bandStub(view, w, h, max_iter, y0, rows, band, orbit);
        }
    }.call;

    var e = try testEngine();
    defer e.deinit();
    e.use_gpu = true;
    e.gpu_iter_fn = stub;
    try e.iterate();
    const iters_before = e.iteration_passes;
    try e.setGradient(solidGradient(.{ 255, 0, 0, 255 }));
    try testing.expectEqual(iters_before, e.iteration_passes); // NEVER re-iterated
}

// ─── M6: the shallow render path is untouched by the precision split ──────────

/// A 16x16 render of `defaultView()` at max_iter 512, captured from commit `d04e96c` (the
/// commit before the `f128` view center landed) and asserted here BIT-exactly. The samples
/// span the image: first pixel, second row, an interior sentinel, the last pixel.
///
/// This is the regression guard for M6's core promise: widening the view center to `f128`
/// must not perturb the f64 per-pixel path by one bit. `rectViewport` narrows the center
/// once with `@floatCast`, so at a shallow view (whose center IS an exact f64) every
/// downstream value is the value it was before.
const shallow_golden = [_]struct { i: usize, v: f32 }{
    .{ .i = 0, .v = 1.5789121 },
    .{ .i = 17, .v = 1.7890291 },
    .{ .i = 40, .v = 3.209162 },
    .{ .i = 100, .v = 4.6606684 },
    .{ .i = 136, .v = -1.0 }, // interior sentinel
    .{ .i = 200, .v = 3.9255261 },
    .{ .i = 239, .v = 2.0438528 },
    .{ .i = 255, .v = 1.8785442 },
};

test "the shallow render path is bit-identical at the home view after the f128 widening" {
    const S: u32 = 16;
    var buf: [S * S]f32 = undefined;
    try iterbuf.iterateInto(&buf, testView().rectViewport(S, S), 512);

    for (shallow_golden) |g| {
        try testing.expectEqual(g.v, buf[g.i]);
    }
}

// ─── M6: the path decision, the per-render orbit, and the deep render ─────────
//
// The milestone's reference centre: the seahorse-valley boundary point. Deliberately NOT on the
// real axis, so a vertically flipped image is a gross mismatch rather than a symmetry that hides
// the flip. Shared with `iterbuf.zig`'s deep tests, which is why these numbers must match.
const m6_center = viewport.ComplexHi{
    .re = -0.743643887037158704752191506114774,
    .im = 0.131825904205311970493132056385139,
};

/// Side of the (small) images the deep engine tests render. Deep pixels are ~100× a shallow
/// pixel's cost, so keep the count low and the assertions sharp.
const deep_side: u32 = 16;

/// The reference deep view for these tests, and the `max_iter` it NEEDS. Both matter: at 1e-9
/// the whole 16x16 image is inside `perturb.threshold_side` and resolves 256 distinct values at
/// 4096 iterations — but only 1 (all interior) at 512, because a deep view is iteration-limited
/// long before it is precision-limited. A "deep" fixture with too small a `max_iter` renders a
/// FLAT image, against which an identity or fallback assertion proves nothing.
const deep_test_side: f64 = 1.0e-9;
const deep_test_iter: u32 = 4096;

fn deepView(side: f64) !SquareView {
    return SquareView.fromCenterSide(m6_center, side);
}

/// An engine at the reference centre, `side` wide, `deep_side` px square, with `max_iter` PINNED
/// (`manual`) so the depth under test is not silently re-decided by the auto ramp.
fn deepEngine(side: f64, max_iter: u32) !Engine {
    return Engine.init(testing.allocator, try deepView(side), deep_side, try IterPolicy.manual(max_iter));
}

/// An engine on the reference deep view, resolved (256 distinct values on a correct render).
fn resolvedDeepEngine() !Engine {
    return deepEngine(deep_test_side, deep_test_iter);
}

/// Count how many distinct bit patterns a smooth buffer holds — the measure of whether a deep
/// render resolved structure or collapsed to one flat value.
fn distinctValues(values: []const f32) !usize {
    var seen = std.AutoHashMap(u32, void).init(testing.allocator);
    defer seen.deinit();
    for (values) |v| try seen.put(@bitCast(v), {});
    return seen.count();
}

test "usesDeepPath switches exactly at perturb.threshold_side, inclusive" {
    const t = perturb.threshold_side;
    var deep = try deepEngine(t, 512);
    defer deep.deinit();
    try testing.expect(deep.usesDeepPath()); // AT the threshold: deep

    try deep.installView(try deepView(std.math.nextAfter(f64, t, 1.0)));
    try testing.expect(!deep.usesDeepPath()); // one ulp above: shallow

    try deep.installView(try deepView(std.math.nextAfter(f64, t, 0.0)));
    try testing.expect(deep.usesDeepPath()); // one ulp below: deep
}

test "a shallow render computes no reference orbit at all" {
    var e = try testEngine();
    defer e.deinit();
    try e.iterate();
    try testing.expectEqual(@as(u32, 0), e.orbit_computations);
    try testing.expectEqual(@as(?*const perturb.ReferenceOrbit, null), e.orbitPtr());
}

test "a one-shot deep render computes exactly one reference orbit" {
    var e = try resolvedDeepEngine();
    defer e.deinit();
    try e.iterate();
    try testing.expectEqual(@as(u32, 1), e.orbit_computations);
}

test "a progressive deep render of many chunks still computes exactly one reference orbit" {
    // The load-bearing economy of the deep path: the `f128` orbit loop is the expensive part,
    // and a 16-row image drained 3 rows at a time is 6 chunks. One orbit, not six.
    var e = try resolvedDeepEngine();
    defer e.deinit();
    try e.beginPass(deep_side, deep_side);
    try drainPass(&e, 3);
    try testing.expectEqual(@as(u32, 1), e.orbit_computations);
}

test "a completed render logs exactly one render-path summary, one-shot or progressive" {
    var e = try resolvedDeepEngine();
    defer e.deinit();
    try e.iterate();
    try testing.expectEqual(@as(u32, 1), e.path_summaries);

    try e.beginPass(deep_side, deep_side);
    try drainPass(&e, 3); // six chunks, ONE more summary
    try testing.expectEqual(@as(u32, 2), e.path_summaries);
}

test "a progressive deep render is scalar-identical to the one-shot deep render" {
    // Chunking must not change one bit of the deep image either — the same guarantee M5 pinned
    // for the shallow path, now across a shared orbit and band-local writes.
    var one_shot = try resolvedDeepEngine();
    defer one_shot.deinit();
    try one_shot.iterate();

    var chunked = try resolvedDeepEngine();
    defer chunked.deinit();
    try chunked.beginPass(deep_side, deep_side);
    try drainPass(&chunked, 3);

    // Non-flat first, or "identical" would be satisfied by two all-interior images.
    try testing.expect(try distinctValues(one_shot.iter) > 1);
    try testing.expectEqual(@as(usize, 0), diffCountF32(one_shot.iter, chunked.iter));
}

test "a completed deep progressive pass bumps each counter exactly once" {
    var e = try resolvedDeepEngine();
    defer e.deinit();
    try e.beginPass(deep_side, deep_side);
    try drainPass(&e, 3);
    try testing.expectEqual(@as(u32, 1), e.iteration_passes);
    try testing.expectEqual(@as(u32, 1), e.color_passes);
}

test "cancelPass frees the abandoned deep pass's orbit, and re-beginning computes a fresh one" {
    // Run under `testing.allocator`: a retained orbit here would be reported as a LEAK, which is
    // the real assertion. Repeated begin/cancel is what a user zooming continuously produces.
    var e = try resolvedDeepEngine();
    defer e.deinit();

    var round: u32 = 0;
    while (round < 3) : (round += 1) {
        try e.beginPass(deep_side, deep_side);
        _ = try e.stepPassRows(2); // partway in: the orbit now exists
        try testing.expect(e.orbitPtr() != null);
        e.cancelPass();
        try testing.expectEqual(@as(?*const perturb.ReferenceOrbit, null), e.orbitPtr());
    }
    try testing.expectEqual(@as(u32, 3), e.orbit_computations); // one per abandoned render
}

test "a completed deep render leaves no orbit behind" {
    var e = try resolvedDeepEngine();
    defer e.deinit();
    try e.iterate();
    try testing.expectEqual(@as(?*const perturb.ReferenceOrbit, null), e.orbitPtr());
}

test "a one-shot render supersedes an in-flight deep pass's orbit instead of reusing it" {
    // `iterate` after a partial pass at another view must not colour the new image with the old
    // view's orbit. Two renders happened, so two orbits were computed.
    var e = try resolvedDeepEngine();
    defer e.deinit();
    try e.beginPass(deep_side, deep_side);
    _ = try e.stepPassRows(2);
    try e.setViewport(try deepView(2.0e-9));
    try testing.expectEqual(@as(u32, 2), e.orbit_computations);
    try testing.expectEqual(@as(?*const perturb.ReferenceOrbit, null), e.orbitPtr());
}

test "an 8x8 render at side 1e-30 through the engine resolves mostly distinct values" {
    // THE milestone, end to end through the public API: at 1e-30 every pixel's `f64` `c` is the
    // same number, so the pre-M6 renderer produced one flat colour. `max_iter` is pinned rather
    // than left to the auto policy so this test pins the deep PATH and nothing else; T5 has
    // since raised `auto_max_iter` to the same 65536, so the auto policy reaches this count at
    // this depth by itself (pinned in `autoiter.zig`).
    const S: u32 = 8;
    var e = try Engine.init(testing.allocator, try deepView(1.0e-30), S, try IterPolicy.manual(65536));
    defer e.deinit();
    try e.iterate();
    try testing.expect(try distinctValues(e.iter) >= 56); // 64 pixels
}

test "an 8x8 render at side 1e-30 resolves detail under the DEFAULT auto policy" {
    // M6/T5's user-visible unlock, end to end and without a hand-pinned count: what an actual
    // user gets. Before T5 the auto ramp stopped at 4096 here and this same render came back as
    // a single flat colour, so this asserts BOTH halves — the ramp reaches its ceiling at this
    // depth, and that count is enough to resolve the image.
    const S: u32 = 8;
    var e = try Engine.init(testing.allocator, try deepView(1.0e-30), S, .{});
    defer e.deinit();
    try testing.expectEqual(autoiter.auto_max_iter, e.max_iter);
    try e.iterate();
    try testing.expect(try distinctValues(e.iter) >= 56); // 64 pixels
}

/// A 16x16 render of the reference centre at side 1e-3 (a SHALLOW view: 1000x above
/// `perturb.threshold_side`) with `max_iter` 512, captured from the tree BEFORE the deep path
/// was wired in and asserted here bit-exactly.
///
/// This is M6's other promise, the one that is easy to break silently: adding a second iteration
/// path must not perturb the first by one bit. The samples span the image, and index 100 is an
/// interior sentinel.
const shallow_1e3_golden = [_]struct { i: usize, v: f32 }{
    .{ .i = 0, .v = 36.18602 },
    .{ .i = 17, .v = 36.594677 },
    .{ .i = 40, .v = 40.206276 },
    .{ .i = 100, .v = -1.0 }, // interior sentinel
    .{ .i = 136, .v = 125.48962 },
    .{ .i = 200, .v = 61.921837 },
    .{ .i = 239, .v = 68.322136 },
    .{ .i = 255, .v = 69.98453 },
};

test "a view just above the threshold still renders shallow, bit-identically to before M6" {
    var e = try deepEngine(1.0e-3, 512);
    defer e.deinit();
    try testing.expect(!e.usesDeepPath());
    try e.iterate();

    for (shallow_1e3_golden) |g| {
        try testing.expectEqual(g.v, e.iter[g.i]);
    }
    try testing.expectEqual(@as(u32, 0), e.orbit_computations);
}

test "THE GUARANTEE holds at a deep view: the three colour setters never re-iterate" {
    // The decoupling has to survive the expensive path, which is where it MATTERS: a palette
    // tweak at 1e-25 must not pay for a reference orbit and 65536-deep deltas again. 8x8 and
    // 65536 iterations is what that depth needs to resolve (44 distinct values) — the guarantee
    // is asserted over a REAL deep image, not a flat one.
    var e = try Engine.init(testing.allocator, try deepView(1.0e-25), 8, try IterPolicy.manual(65536));
    defer e.deinit();
    try e.iterate();
    try testing.expect(e.usesDeepPath());
    try testing.expect(try distinctValues(e.iter) > 1);
    const iters = e.iteration_passes;
    const orbits = e.orbit_computations;

    try e.setGradient(solidGradient(.{ 255, 0, 0, 255 }));
    try e.setMapping(.{ .mode = .cyclic, .period = 8.0 });
    try e.setInterior(.{ 0, 0, 255, 255 });

    try testing.expectEqual(iters, e.iteration_passes); // NEVER re-iterated
    try testing.expectEqual(orbits, e.orbit_computations); // and no new orbit either
    try testing.expectEqual(@as(u32, 4), e.color_passes); // the render's, plus three edits
}

test "a GPU backend that refuses the deep path falls back to the CPU and still renders deep" {
    // What `main.zig` wires today: `gpuIterFn` errors on a non-null orbit (the shader is T6's).
    // The fallback must produce the DEEP image, not a flat one.
    const stub = struct {
        fn call(
            view: SquareView,
            w: u32,
            h: u32,
            max_iter: u32,
            y0: u32,
            rows: u32,
            band: []f32,
            orbit: ?*const perturb.ReferenceOrbit,
        ) anyerror!void {
            try bandStub(view, w, h, max_iter, y0, rows, band, orbit);
        }
    }.call;

    var e = try resolvedDeepEngine();
    defer e.deinit();
    e.use_gpu = true;
    e.gpu_iter_fn = stub;
    try e.iterate();

    try testing.expectEqual(@as(u32, 1), e.iteration_passes);
    try testing.expect(try distinctValues(e.iter) > 1); // not the flat image f64 would give
}

test "the engine's path summary names the deep path and the depth it is used at" {
    var e = try deepEngine(1.0e-30, 512);
    defer e.deinit();
    var buf: [perturb.path_summary_buf_len]u8 = undefined;
    try testing.expectEqualStrings(
        try perturb.pathSummary(&buf, 1.0e-30, true),
        try e.pathSummary(&buf),
    );
}

test "an orbit allocation failure is reported and leaves the engine renderable" {
    // `fail_index = 2` lets `init`'s two buffers through and fails the orbit. The deep render
    // must surface `OutOfMemory` (not a wrong image), and a shallower view — which allocates
    // nothing — must still render afterwards.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2 });
    var e = try Engine.initRect(failing.allocator(), try deepView(1.0e-9), deep_side, deep_side, try IterPolicy.manual(512));
    defer e.deinit();

    try testing.expectError(error.OutOfMemory, e.iterate());
    try testing.expectEqual(@as(u32, 0), e.iteration_passes);
    try testing.expectEqual(@as(?*const perturb.ReferenceOrbit, null), e.orbitPtr());

    try e.installView(testView()); // shallow: no allocation, no orbit
    try e.iterate();
    try testing.expectEqual(@as(u32, 1), e.iteration_passes);
}

test "a hand-built non-finite deep centre is rejected before any orbit is attempted" {
    // `perturb.OrbitError.NonFiniteCenter` is in `IterateError` (and in `orbitFailureMessage`'s
    // buffer bound) but is UNREACHABLE through the engine: `validateGeometry` re-runs T1's
    // `fromCenterSide` first, so a hand-built view fails as `DegenerateRegion` and no orbit is
    // allocated for a centre that has no orbit. Pinned so the ordering is not "simplified" away.
    var e = try resolvedDeepEngine();
    defer e.deinit();
    e.view = SquareView{ .center_re = std.math.nan(f128), .center_im = 0.0, .side = deep_test_side };
    try testing.expectError(viewport.ViewportError.DegenerateRegion, e.iterate());
    try testing.expectEqual(@as(u32, 0), e.orbit_computations);
}

test "orbitFailureMessage names the failure, the depth, the count and the ways out" {
    var buf: [orbit_message_buf_len]u8 = undefined;
    try testing.expectEqualStrings(
        "deep zoom reference orbit failed (OutOfMemory) at view side 1e-30 with " ++
            "max_iter=65536; zoom out or lower max_iter — the previous image is still on screen",
        try orbitFailureMessage(&buf, error.OutOfMemory, 1.0e-30, 65536),
    );
}

test "orbit_message_buf_len fits the worst-case message" {
    var buf: [orbit_message_buf_len]u8 = undefined;
    const message = try orbitFailureMessage(
        &buf,
        error.NonFiniteCenter,
        -std.math.floatMin(f64),
        std.math.maxInt(u32),
    );
    try testing.expect(message.len <= orbit_message_buf_len);
}

test "orbitFailureMessage reports NoSpaceLeft rather than truncating into a shorter buffer" {
    var buf: [8]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, orbitFailureMessage(&buf, error.OutOfMemory, 1.0e-30, 512));
}
