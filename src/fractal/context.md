<!-- LLM-only for src/fractal/. Imperative,<=500 words,shipped APIs only. -->

# src/fractal/ context

## Purpose

Pure core: view → Mandelbrot image. NEVER import SDL/GPU/`c.zig`/`@cImport`. No
globals/clock/random; register each module in `src/root.zig`'s `test`. Failures: TYPED
error + pure message builder; ONLY `engine.zig` logs (`std.log(.fractal)`).

Decoupling: ITERATE ONCE into a persistent `[]f32`; palette edits rerun ONLY the CHEAP color
pass (`iterbuf`→`colorpass`: baked `gradient` LUT + `mapping`→RGBA8).

## Precision split

`ComplexHi{re,im:f128}`+`.lo()`=where the view IS;`Complex`/`Viewport`=where a pixel is
RELATIVE to it,ALWAYS f64. `f128` is software-emulated (~100× slower): NEVER in a per-pixel
loop—compute the offset in f64,add it ONCE onto the f128 center. ONLY two f128 sites:
`perturb.ReferenceOrbit.compute`(once per render),`mandelbrot.iterateExact`(tests).
Keep `Viewport` f128-FREE and `iterbuf`/`mandelbrot`/GPU f64 end-to-end: shallow renders stay
bit-identical to pre-M6. `side` is f64;`persist.zig` narrows the center on save.

## Modules

- `viewport.zig`—view model+pixel↔complex. `SquareView{center_re,center_im:f128,side:f64}`;
  `defaultView()`=center `-0.75+0i`,side 3.5. Duals `centerMag()`/`fromCenterMag`
  (`magnification()`=`1/(side·√2)`),`corners()`/`fromCorners`(SNAPS square,LARGER axis);
  those+`fromCenterSide(ComplexHi,side)`→`ViewportError.DegenerateRegion`+
  `degenerateRegionMessage(buf[message_buf_len],what,value)`. `center()`→`ComplexHi`,
  `centerLo()`→`Complex`. `pixelToComplex(px,py,S)`/`complexToPixel(c,S)`,hi twins
  `pixelToComplexHi`/`rectPixelToComplexHi(px,py,w,h)`;
  `cursorCoord(wx,wy,ImageRect{x,y,side})`→`?ComplexHi`(null on letterbox);
  `imageViewport(S)`→`Viewport`. Readout:`coordDigits(mag)`→
  `formatCoord(buf[coord_buf_len],ComplexHi,mag)`,`max_coord_digits`=34;`coord_text_buf_len`
  sizes UI buffers. Warn-only zoom floor LIVES HERE:`precision_floor_side`(1e-13),
  `atPrecisionFloor(v)`,`precisionFloorMessage(buf[floor_message_buf_len],side)`.
  RECT render:`rectViewport(w,h)`(scale=`side/min(w,h)`),
  `Viewport.complexToPixel(pt)`+`pixelIndex(pt)→?usize`(null off-image)—NOT the square map.
  ASPECT:`fitImageRect(rx,ry,rw,rh,tex_w,tex_h)`(`scale=min(rw/tw,rh/th)`) centers the TEXTURE
  =the rect for BOTH drawing and mapping;LETTERBOXES,never stretches.
- `navigate.zig`—transforms → a NEW `SquareView`;`factor` scales the SIDE (`<1`=zoom IN).
  `zoomAbout(v,anchor:ComplexHi,f)` pins `anchor` to its pixel;
  `zoomCentered(v,point:ComplexHi,f)` recenters;`panByPixels(v,dpx,dpy,S)` moves the VIEW (pass
  NEGATED mouse delta);`boxSelect(v,a,b,S)` square-snaps a drag;`reset()`=`defaultView()`.
  All→`DegenerateRegion` on bad input/`S==0`/side overflow. RE-EXPORTS viewport's four floor
  names.
- `refine.zig`—`decidePass(interacting,idle_ns,full_pass_done)`→
  `PassDecision{coarse,full,none}`;`idle_threshold_ns`=150 ms.
- `autoiter.zig`—`max_iter` policy; READ,never re-derive. `autoMaxIter(mag) !u32`=
  `clamp(base_max_iter(512)+iter_per_doubling(80)·log2(mag/default_magnification),512,
  auto_max_iter(4096))`,MONOTONE;bad `mag`→`InvalidMagnification`. 4096 caps the RAMP only;
  PINNED values go past it,to `max_manual_iter`(2^24,f32-exact).
  `IterPolicy{auto=true,manual_value=512}`:`manual(v)` demands
  `[min_manual_iter(16),max_manual_iter]`,else `MaxIterOutOfRange`;
  `effective(mag)`=ramp if `auto` else `clampManual(v)`.
  `maxIterRangeMessage(buf,v)`,`policySummary(buf,policy,mag)`.
- `mandelbrot.zig`—`iterate(c_re,c_im,max_iter) f32`→smooth escape else
  `interior_sentinel`(-1.0). `iterateExact(f128,f128,max_iter)`=the SAME algorithm in f128,
  TEST GROUND TRUTH only—never in a renderer.
  `smoothEscapeValue(F,z_re,z_im,c_re,c_im,escape_n)`=the ONE colouring tail
  (`extra_iterations`,`n+1−log2(log2|z|)`,non-finite→`escape_n`):CALL it,never restate it.
- `perturb.zig`—DEEP path at/below `threshold_side`(1e-6);pure,LOG-FREE.
  `ReferenceOrbit.compute(alloc,center:ComplexHi,max_iter)` iterates the CENTRE in f128,stores
  `Z_0..Z_k` as f64 `re`/`im`(f128 entries would only cost a conversion:deltas are f64);
  `len()`,`deinit(alloc)`,`capacity`=allocation(slices TRIMMED when the centre escapes—normal);
  `re[0]=im[0]=0`(`Z_0`),`re[1]`=C;non-finite→`OrbitError.NonFiniteCenter`.
  `iterateDelta(orbit BY VALUE,dc_re,dc_im,max_iter) f32`:`δ←2·Z_m·δ+δ²+δc`,escape on
  `|Z_m+δ|²>4`,f64 THROUGHOUT(NEVER widen),coloured by `smoothEscapeValue`⇒comparable to
  `iterate`. REBASE(Zhuoran) when `|Z_m+δ|<|δ|` or `m+1==len()`:`δ←Z_m+δ`,`m←0`—EXACT because
  `Z_0=0`;ONE centre orbit then serves every pixel,no glitches. T6:`gpu_floor_side`(1e-20),
  `gpu_max_orbit_len`(2^17=1 MiB as float2),`FallbackReason`+
  `gpuFallbackMessage(buf,reason)`/`fallback_message_buf_len`,
  `pathSummary(buf,side,used_deep)`/`path_summary_buf_len`.
- `gradient.zig`—`Stop{pos:f32∈[0,1],color:Rgba8}`;ASCENDING fixed-cap array(`max_stops`=32):
  `fromStops`,`stops()`,`bakeLut(g,out:*[lut_size=1024]Rgba8)`,`default()`.
- `mapping.zig`—`Mode{linear,log,cyclic}`;`Params{mode,period=default_period(32.0)}`
  (cyclic-only,>0);`mapToUnit(smooth,max_iter,params)` CLAMPED [0,1);bad→0.
- `iterbuf.zig`—ITERATION only. `iterationBufferLen(vp)`=w*h;`iterateInto(buf,vp,max_iter)`
  PURE(pixel centers;bad `buf.len`→`BufferSizeMismatch`);
  `iterateRowsInto(buf,vp,max_iter,y0,rows)` band-only/composable,
  overrun→`RowRangeOutOfBounds`;`iterateBandInto(band,…)`=same but buffer-LOCAL (row `y0`
  at index 0 = the GPU's contract);`iterate(...)`→`IterationResult{values,elapsed_ns}`.
- `progressive.zig`—PURE chunk scheduler+upsampler.
  `Pass{rows_total,rows_done,chunk_rows}`: `fraction()`,`done()`,`nextChunk()`(never 0),
  `advance(rows,elapsed_ns)`. `adaptChunkRows(rows,elapsed_ns,target_ns)` re-times toward
  `target_chunk_ns`(0.5 s REPAINT budget),≤4×/step,clamped `1..max_chunk_rows`;
  `initial_chunk_rows`=4. `progressLabel(buf[progress_label_buf_len],f)`→`"rendering 42%"`.
  `upsampleInto(dst,dw,dh,src,sw,sh)`=nearest-neighbour BLOCKY preview.
- `colorpass.zig`—`colorInto(rgba,iter,lut,max_iter,params,interior)` PURE;
  `rgba.len==iter.len*4` checked BEFORE any write; sentinel→`interior`;alpha FORCED 255.
- `engine.zig`—DECOUPLING crux. Owns `view`,`image_side`,`policy`,DERIVED `max_iter`,
  `iter:[]f32`/`rgba:[]u8`,`gradient`+`lut`,`params`,`interior`,`iteration_passes`/`color_passes`.
  `use_gpu`+`gpu_iter_fn:?IterFn(view,w,h,max_iter,y0,rows,band)`=one row BAND per call;BOTH
  backends chunk,a failed band falls back to CPU. `init` does NOT iterate.
  `setViewport`/`setPolicy`/`resize` re-iterate (bump BOTH counters);
  `setGradient`/`setMapping`/`setInterior`=color pass ONLY,`iteration_passes` UNCHANGED (THE
  GUARANTEE). NON-BLOCKING,PREFER:`installView(v)`/`installPolicy(p)` refresh `max_iter`,render
  NOTHING;`beginPass(w,h)` reallocs+seeds the BLOCKY preview (`upsampleInto`,else black);
  `stepPass()`=one self-timed chunk (`stepPassRows(rows)` deterministic),
  `true`=complete→bumps each counter ONCE,clears `pass:?progressive.Pass`;`cancelPass()` on
  input change;`passFraction()→?f32` drives the progress bar.
- `persist.zig`—pure JSON. `AppState` heap-owns `stops`+`mapping_mode` →
  ALWAYS `freeState(state,alloc)`. `fromEngine`→`toJson(buf)`,`fromJson(json,alloc)`,
  `applyToEngine`(color setters first,`setViewport` LAST).
  `ParseError{InvalidJson,MissingField,InvalidField,GradientEmpty,GradientNotSorted}`.

## Conventions

Pixel: origin TOP-LEFT,y DOWN,+0.5=center;`im` UP—pixel→complex NEGATES y.
Tests: in-file,one intent each.
