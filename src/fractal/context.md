<!-- LLM-only for src/fractal/. Imperative, <=500 words, shipped APIs only. -->

# src/fractal/ context

## Purpose

Pure core: view → Mandelbrot image. NEVER import SDL/GPU/`c.zig`/`@cImport` (fast test tier). No
globals/clock/random; register each module in `src/root.zig`'s `test` block. Failures: TYPED
errors (never `unreachable`) + a pure message builder. ONLY `engine.zig` logs
(`std.log(.fractal)`, strings from those builders).

Decoupling: ITERATION runs ONCE into a persistent `[]f32`; palette edits rerun ONLY the CHEAP
color pass (`iterbuf`→`colorpass`, baked `gradient` LUT + `mapping` → RGBA8).

## Modules

- `viewport.zig` — view model + pixel↔complex. `SquareView{center_re,center_im,side:f64}`;
  `defaultView()`=center `-0.75+0i`, side 3.5. Duals `centerMag()`/`fromCenterMag`
  (`magnification()`=`1/(side·√2)`), `corners()`/`fromCorners` (SNAPS square by the LARGER axis);
  those + `fromCenterSide` → `ViewportError.DegenerateRegion` +
  `degenerateRegionMessage(buf[message_buf_len],what,value)`.
  `pixelToComplex(px,py,S)`/`complexToPixel(c,S)` (assert `S>0`);
  `cursorCoord(wx,wy,ImageRect{x,y,side})`→`?Complex`, null on letterbox; `imageViewport(S)`→
  `Viewport` for `iterbuf`. Readout: `coordDigits(mag)`=`clamp(4+ceil(log10 mag),4,17)` →
  `formatCoord(buf[coord_buf_len],c,mag)`.
  RECT render: `rectViewport(w,h)` (scale=`side/min(w,h)`), `Viewport.complexToPixel(pt)` +
  `pixelIndex(pt)→?usize` (`w` stride, null off-image) for per-pixel lookups (NOT the square map).
  ASPECT: `fitImageRect(rx,ry,rw,rh,tex_w,tex_h)` fits the TEXTURE in the region
  (`scale=min(rw/tw,rh/th)`, centered) = the rect for BOTH drawing and mapping: mismatched
  aspect letterboxes, never stretches (supersedes `computeImageRect`).
- `navigate.zig` — transforms → a NEW `SquareView`; `factor` scales the SIDE (`<1`=zoom IN).
  `zoomAbout(v,anchor,f)` pins `anchor` to its pixel;
  `zoomCentered(v,point,f)` recenters; `panByPixels(v,dpx,dpy,S)` moves the VIEW (pass NEGATED
  mouse delta); `boxSelect(v,a,b,S)` square-snaps a drag; `reset()`=`defaultView()`.
  All→`DegenerateRegion` on bad input/`S==0`/side overflow. Warn-only floor:
  `atPrecisionFloor(v)` (`precision_floor_side`=1e-13) + `precisionFloorMessage(buf,side)`.
- `refine.zig` — coarse→fine. `PassDecision{coarse,full,none}`;
  `decidePass(interacting,idle_ns,full_pass_done)`; `idle_threshold_ns`=150 ms.
- `autoiter.zig` — `max_iter` policy; READ, never re-derive. `autoMaxIter(mag) !u32`=
  `clamp(base_max_iter(512)+iter_per_doubling(80)·log2(mag/default_magnification),512,
  max_max_iter(4096))`, round-to-nearest, MONOTONE; bad `mag`→`InvalidMagnification`.
  `IterPolicy{auto=true,manual_value=512}`: `manual(v)` needs `[min_manual_iter(16),4096]` else
  `MaxIterOutOfRange`; `effective(mag)`= ramp when `auto` else `clampManual(v)`.
  `maxIterRangeMessage(buf,v)`, `policySummary(buf,policy,mag)` (via `effective`).
- `mandelbrot.zig` — `iterate(c_re,c_im,max_iter) f32`→smooth escape else
  `interior_sentinel`(-1.0).
- `gradient.zig` — `Stop{pos:f32 in [0,1],color:Rgba8}`; ASCENDING fixed-cap (`max_stops`=32)
  array: `fromStops` (asserts), `stops()`, `bakeLut(g,out:*[lut_size=1024]Rgba8)`, `default()`.
- `mapping.zig` — `Mode{linear,log,cyclic}`; `Params{mode,period=default_period(32.0)}`
  (cyclic-only, >0); `mapToUnit(smooth,max_iter,params)` CLAMPED [0,1); bad→0.
- `iterbuf.zig` — ITERATION only. `iterationBufferLen(vp)`=w*h; `iterateInto(buf,vp,max_iter)`
  PURE (pixel centers; bad `buf.len`→`BufferSizeMismatch`);
  `iterateRowsInto(buf,vp,max_iter,y0,rows)` writes ONLY that band (bands compose;
  overrun→`RowRangeOutOfBounds`); `iterate(...)`→`IterationResult{values,elapsed_ns}`.
- `progressive.zig` (M5) — PURE chunk scheduler + preview upsampler.
  `Pass{rows_total,rows_done,chunk_rows}`: `fraction()`, `done()`, `nextChunk()` (never 0),
  `advance(rows,elapsed_ns)`. `adaptChunkRows(rows,elapsed_ns,target_ns)` re-times toward
  `target_chunk_ns`(12 ms), ≤4×, clamped `1..max_chunk_rows`; `initial_chunk_rows`=4.
  `progressLabel(buf[progress_label_buf_len],f)`→`"rendering 42%"`.
  `upsampleInto(dst,dw,dh,src,sw,sh)` — nearest-neighbour BLOCKY preview.
- `colorpass.zig` — `colorInto(rgba,iter,lut,max_iter,params,interior)` PURE; `rgba.len==
  iter.len*4` checked BEFORE any write; sentinel→`interior`; alpha FORCED 255.
- `engine.zig` — DECOUPLING crux. Owns `view`,`image_side`,`policy`,DERIVED `max_iter`,
  `iter:[]f32`/`rgba:[]u8`,`gradient`+`lut`,`params`,`interior`,`iteration_passes`/`color_passes`.
  M4: `use_gpu`,`gpu_iter_fn:?IterFn`; `iterate()` routes CPU/GPU with CPU fallback.
  `init` does NOT iterate. `setViewport`/`setPolicy`/`resize` re-iterate (bump BOTH counters);
  `setGradient`/`setMapping`/`setInterior` = color pass ONLY, `iteration_passes` UNCHANGED (THE
  GUARANTEE).
  M5 NON-BLOCKING, prefer over `setViewport` at full res: `installView(v)`/`installPolicy(p)`
  refresh `max_iter` but render NOTHING (no counter moves, old image stays).
  `pass:?progressive.Pass`; `beginPass(w,h)` reallocs + seeds the BLOCKY preview (`upsampleInto`,
  black on failure); `stepPass()`=one ~12 ms chunk (clock picks SIZE only),
  `stepPassRows(rows)` deterministic (GPU: all rows in chunk 1); `true`=complete → bumps each
  counter EXACTLY once, clears `pass`. `cancelPass()` on input change; `passFraction()→?f32`
  for the progress bar.
- `persist.zig` (M5) — pure JSON. `AppState` heap-owns `stops`+`mapping_mode` →
  ALWAYS `freeState(state,alloc)`. `fromEngine`→`toJson(buf)`, `fromJson(json,alloc)`,
  `applyToEngine` (color setters first, `setViewport` LAST).
  `ParseError{InvalidJson,MissingField,InvalidField,GradientEmpty,GradientNotSorted}`.

## Coordinate convention

Pixel: origin TOP-LEFT, y DOWN, +0.5=center; `im` UP — pixel→complex NEGATES y.
Tests in-file, one intent each.
