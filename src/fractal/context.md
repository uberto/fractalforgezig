<!-- LLM-only for src/fractal/. Imperative, <=500 words, shipped APIs only. -->

# src/fractal/ context

## Purpose

Pure core: view → Mandelbrot image. NEVER import SDL/GPU/`c.zig`/`@cImport`. No
globals/clock/random; register each module in `src/root.zig`'s `test` block. Failures: TYPED
errors + a pure message builder. ONLY `engine.zig` logs
(`std.log(.fractal)`, using those builders).

Decoupling: ITERATION runs ONCE into a persistent `[]f32`; palette edits rerun ONLY the CHEAP
color pass (`iterbuf`→`colorpass`, baked `gradient` LUT + `mapping` → RGBA8).

## Modules

- `viewport.zig` — view model + pixel↔complex. `SquareView{center_re,center_im,side:f64}`;
  `defaultView()`=center `-0.75+0i`, side 3.5. Duals `centerMag()`/`fromCenterMag`
  (`magnification()`=`1/(side·√2)`), `corners()`/`fromCorners` (SNAPS square, LARGER axis);
  those + `fromCenterSide` → `ViewportError.DegenerateRegion` +
  `degenerateRegionMessage(buf[message_buf_len],what,value)`.
  `pixelToComplex(px,py,S)`/`complexToPixel(c,S)`;
  `cursorCoord(wx,wy,ImageRect{x,y,side})`→`?Complex`, null on letterbox; `imageViewport(S)`→`Viewport`. Readout: `coordDigits(mag)`→`formatCoord(buf[coord_buf_len],c,mag)`.
  RECT render: `rectViewport(w,h)` (scale=`side/min(w,h)`), `Viewport.complexToPixel(pt)` +
  `pixelIndex(pt)→?usize` (null off-image) — NOT the square map.
  ASPECT: `fitImageRect(rx,ry,rw,rh,tex_w,tex_h)` fits the TEXTURE in the region
  (`scale=min(rw/tw,rh/th)`, centered) = the rect for BOTH drawing and mapping; a mismatched
  aspect letterboxes, never stretches.
- `navigate.zig` — transforms → a NEW `SquareView`; `factor` scales the SIDE (`<1`=zoom IN).
  `zoomAbout(v,anchor,f)` pins `anchor` to its pixel;
  `zoomCentered(v,point,f)` recenters; `panByPixels(v,dpx,dpy,S)` moves the VIEW (pass NEGATED
  mouse delta); `boxSelect(v,a,b,S)` square-snaps a drag; `reset()`=`defaultView()`.
  All→`DegenerateRegion` on bad input/`S==0`/side overflow. Warn-only floor:
  `atPrecisionFloor(v)`(`precision_floor_side`=1e-13) + `precisionFloorMessage(buf,side)`.
- `refine.zig` — `PassDecision{coarse,full,none}`;
  `decidePass(interacting,idle_ns,full_pass_done)`; `idle_threshold_ns`=150 ms.
- `autoiter.zig` — `max_iter` policy; READ, never re-derive. `autoMaxIter(mag) !u32`=
  `clamp(base_max_iter(512)+iter_per_doubling(80)·log2(mag/default_magnification),512,
  auto_max_iter(4096))`, MONOTONE; bad `mag`→`InvalidMagnification`.
  4096 caps the RAMP only (=the f64 zoom floor); PINNED values go far past it, to
  `max_manual_iter`(2^24, the f32-exact limit).
  `IterPolicy{auto=true,manual_value=512}`: `manual(v)` needs
  `[min_manual_iter(16),max_manual_iter]` else `MaxIterOutOfRange`;
  `effective(mag)`=ramp if `auto` else `clampManual(v)`.
  `maxIterRangeMessage(buf,v)`, `policySummary(buf,policy,mag)`.
- `mandelbrot.zig` — `iterate(c_re,c_im,max_iter) f32`→smooth escape else
  `interior_sentinel`(-1.0).
- `gradient.zig` — `Stop{pos:f32∈[0,1],color:Rgba8}`; ASCENDING fixed-cap array (`max_stops`=32):
  `fromStops`, `stops()`, `bakeLut(g,out:*[lut_size=1024]Rgba8)`, `default()`.
- `mapping.zig` — `Mode{linear,log,cyclic}`; `Params{mode,period=default_period(32.0)}`
  (cyclic-only, >0); `mapToUnit(smooth,max_iter,params)` CLAMPED [0,1); bad→0.
- `iterbuf.zig` — ITERATION only. `iterationBufferLen(vp)`=w*h; `iterateInto(buf,vp,max_iter)`
  PURE (pixel centers; bad `buf.len`→`BufferSizeMismatch`);
  `iterateRowsInto(buf,vp,max_iter,y0,rows)` writes ONLY that band, bands compose,
  overrun→`RowRangeOutOfBounds`; `iterateBandInto(band,…)` = same, buffer-LOCAL (row `y0`
  at index 0 = the GPU's contract); `iterate(...)`→`IterationResult{values,elapsed_ns}`.
- `progressive.zig` — PURE chunk scheduler + upsampler.
  `Pass{rows_total,rows_done,chunk_rows}`: `fraction()`, `done()`, `nextChunk()`(never 0),
  `advance(rows,elapsed_ns)`. `adaptChunkRows(rows,elapsed_ns,target_ns)` re-times toward
  `target_chunk_ns`(0.5 s: a REPAINT budget, NOT a frame), ≤4×, clamped
  `1..max_chunk_rows`; `initial_chunk_rows`=4.
  `progressLabel(buf[progress_label_buf_len],f)`→`"rendering 42%"`.
  `upsampleInto(dst,dw,dh,src,sw,sh)` — nearest-neighbour BLOCKY preview.
- `colorpass.zig` — `colorInto(rgba,iter,lut,max_iter,params,interior)` PURE;
  `rgba.len==iter.len*4` checked BEFORE any write; sentinel→`interior`; alpha FORCED 255.
- `engine.zig` — DECOUPLING crux. Owns `view`,`image_side`,`policy`,DERIVED `max_iter`,
  `iter:[]f32`/`rgba:[]u8`,`gradient`+`lut`,`params`,`interior`,`iteration_passes`/`color_passes`.
  M4: `use_gpu`,`gpu_iter_fn:?IterFn(view,w,h,max_iter,y0,rows,band)` — one row BAND per
  call: BOTH backends chunk, a failed band falls back to CPU.
  `init` does NOT iterate. `setViewport`/`setPolicy`/`resize` re-iterate (bump BOTH counters);
  `setGradient`/`setMapping`/`setInterior` = color pass ONLY, `iteration_passes` UNCHANGED (THE
  GUARANTEE).
  M5 NON-BLOCKING (prefer over full-res `setViewport`): `installView(v)`/`installPolicy(p)`
  refresh `max_iter` but render NOTHING (no counters move, old image stays).
  `pass:?progressive.Pass`; `beginPass(w,h)` reallocs + seeds the BLOCKY preview (`upsampleInto`,
  else black); `stepPass()`=one self-timed chunk (`stepPassRows(rows)` deterministic);
  `true`=complete → bumps each counter EXACTLY once, clears `pass`. `cancelPass()` on input
  change; `passFraction()→?f32` drives the progress bar.
- `persist.zig` — pure JSON. `AppState` heap-owns `stops`+`mapping_mode` →
  ALWAYS `freeState(state,alloc)`. `fromEngine`→`toJson(buf)`, `fromJson(json,alloc)`,
  `applyToEngine` (color setters first, `setViewport` LAST).
  `ParseError{InvalidJson,MissingField,InvalidField,GradientEmpty,GradientNotSorted}`.

## Coordinate convention

Pixel: origin TOP-LEFT, y DOWN, +0.5=center; `im` UP — pixel→complex NEGATES y.
Tests: in-file, one intent each.
