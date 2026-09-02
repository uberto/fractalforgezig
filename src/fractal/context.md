<!-- LLM-only for src/fractal/. Imperative,<=500 words,shipped APIs only. -->

# src/fractal/ context

Pure core:view→Mandelbrot image. NEVER import SDL/GPU/`c.zig`/`@cImport`. No
globals/clock/random;register every module in `src/root.zig`'s `test`.
Failures:TYPED error+pure message builder;ONLY `engine.zig` logs(`std.log(.fractal)`).

Decoupling:ITERATE ONCE into persistent `[]f32`;palette edits rerun ONLY CHEAP
`colorpass`(baked `gradient` LUT+`mapping`→RGBA8),NEVER `iterbuf`.

## Precision split

`ComplexHi{re,im:f128}`+`.lo()`=where view IS;`Complex`/`Viewport`=pixel RELATIVE to it,ALWAYS
f64. `f128` software-emulated(~100× slower):NEVER per-pixel—offset f64,added ONCE onto centre.
ONLY 2 f128 sites:`perturb.ReferenceOrbit.compute`,`mandelbrot.iterateExact`.
`Viewport`/`iterbuf`/`mandelbrot`/GPU stay f64 end-to-end⇒shallow renders match pre-M6.

## Modules

- `viewport.zig`—view model+pixel↔complex. `SquareView{center_re,center_im:f128,side:f64}`;
  `defaultView()`=center `-0.75+0i`,side 3.5. Duals `centerMag()`/`fromCenterMag`
  (`magnification()`=`1/(side·√2)`),`corners()`/`fromCorners`(SNAPS square,LARGER-axis);
  those+`fromCenterSide(ComplexHi,side)`→`ViewportError.DegenerateRegion`+
  `degenerateRegionMessage(buf[message_buf_len],what,value)`. `center()`→`ComplexHi`,
  `centerLo()`→`Complex`. `pixelToComplex(px,py,S)`/`complexToPixel(c,S)`,hi-twins
  `pixelToComplexHi`/`rectPixelToComplexHi(px,py,w,h)`;
  `cursorCoord(window_x,window_y,ImageRect{x,y,side})`→`?ComplexHi`(null-letterbox);
  `imageViewport(S)`→`Viewport`. Readout:`coordDigits(mag)`→
  `formatCoord(buf[coord_buf_len],ComplexHi,mag)`,`max_coord_digits`=34;`coord_text_buf_len`=UI-buffers.
  Warn-only floor HERE:`precision_floor_side`(1e-30,f128-CENTRE limit),
  `atPrecisionFloor(v)`(strict),`precisionFloorMessage(buf[floor_message_buf_len],side)`.
  RECT render:`rectViewport(w,h)`,`Viewport.complexToPixel(pt)`+`pixelIndex(pt)→?usize`(null
  off-image),NOT square map. ASPECT:`fitImageRect(region_x,region_y,region_w,region_h,tex_w,tex_h)`
  =LETTERBOX fit;centred rect drives drawing+mapping,NEVER stretch.
- `navigate.zig`—transforms→NEW `SquareView`;`factor` scales SIDE(`<1`=zoom IN).
  `zoomAbout(v,anchor:ComplexHi,f)` pins `anchor` to its pixel;`zoomCentered(v,point,f)`
  recenters;`panByPixels(v,dpx,dpy,S)` moves VIEW(NEGATED mouse-delta);`boxSelect(v,a,b,S)`
  square-snaps drags;`reset()`=`defaultView()`.All→`DegenerateRegion` on bad
  input/`S==0`/overflow. RE-EXPORTS viewport's 4 floor-names. `max_view_side`(8.0)=WIDEST-view;
  side-GROWING paths SATURATE.
- `refine.zig`—`decidePass(interacting,idle_ns,full_pass_done,cancelled)`→
  `PassDecision{coarse,full,none}`;`idle_threshold_ns`=150ms;`cancelled`→`.none`=NEVER-re-arm-a-cancelled-view.
- `autoiter.zig`—`max_iter` policy;READ,never re-derive. QUADRATIC ramp,
  `d=@max(0,log2(mag/default_magnification))`:`autoMaxIter(mag) !u32`=
  `clamp(base_max_iter(512)+iter_per_doubling_squared·d²,512,auto_max_iter(65536))`
  (MONOTONE via `@max`);bad `mag`→`InvalidMagnification`.
  `iter_per_doubling_squared`=comptime-DERIVED(`floor_doublings`,`floor_magnification`)⇒ceiling
  hits `viewport.precision_floor_side` EXACTLY;NEVER hard-code. 65536 caps RAMP only;PINNED reach
  `max_manual_iter`(2^24,f32-exact).
  `IterPolicy{auto=true,manual_value=512}`:`manual(v)` demands
  `[min_manual_iter(16),max_manual_iter]`,else `MaxIterOutOfRange`;
  `effective(mag)`=ramp if `auto` else `clampManual(v)`.
  `maxIterRangeMessage(buf,v)`,`policySummary(buf,policy,mag)`.
- `mandelbrot.zig`—`iterate(c_re,c_im,max_iter) f32`→smooth escape else
  `interior_sentinel`(-1.0). `iterateJulia(z0_re,z0_im,c_re,c_im,max_iter)`=Julia twin,seed z0,c
  FIXED,shares loop,f64. `iterateExact(f128,f128,max_iter)`=SAME algorithm in f128,TEST-ONLY;trust
  ~1e-20. `smoothEscapeValue(F,z_re,z_im,c_re,c_im,escape_n)`=THE colouring tail
  (`extra_iterations`,`n+1−log2(log2|z|)`,non-finite→`escape_n`):CALL,never restate.
- `orbit.zig`—PURE orbit sequence for orbit inspector(complex-plane ONLY,no screen map).
  `compute(c_re,c_im,max_iter,out:[][2]f64)→Result{points_written,escaped}`:writes `out[0]={0,0}`
  then `z=z²+c`/step;STOP on `|z|²>bail_radius_squared`(escaping point INCLUDED,escaped=true) or
  buffer full.Interior fills to `max_iter+1`;caller sizes `out≥max_iter+1`;short `out` CLAMPED(never
  OOB).Imports `mandelbrot.bail_radius_squared`—never restate radius.
- `perturb.zig`—DEEP path arithmetic for `side<=threshold_side`(1e-6);pure,LOG-FREE.
  `ReferenceOrbit.compute(alloc,center:ComplexHi,max_iter)` f128-iterates CENTRE,stores
  `Z_0..Z_k` as f64 `re`/`im`;`len()`,`deinit(alloc)`,`capacity`=allocation(TRIMMED if centre
  escapes);`re[0]=im[0]=0`(`Z_0`),`re[1]`=C;→`OrbitError.NonFiniteCenter`.
  `iterateDelta(orbit BY VALUE,dc_re,dc_im,max_iter) f32`:`δ←2·Z_m·δ+δ²+δc`,escape on
  `|Z_m+δ|²>4`,f64 THROUGHOUT(NEVER widen),coloured by `smoothEscapeValue`⇒comparable to
  `iterate`. REBASE(Zhuoran) if `|Z_m+δ|<|δ|`/`m+1==len()`:`δ←Z_m+δ`,`m←0`—EXACT(`Z_0=0`);ONE
  orbit/render. `pathSummary(buf,side,used_deep)`/`path_summary_buf_len`.
  GPU:`gpu_floor_side`(1e-20),`gpu_max_orbit_len`(2^17),`FallbackReason`+
  `gpuFallbackMessage(buf,reason)`/`fallback_message_buf_len`.
- `gradient.zig`—`Stop{pos:f32∈[0,1],color:Rgba8}`;ASCENDING,cap `max_stops`=32:
  `fromStops`,`stops()`,`bakeLut(g,out:*[lut_size=1024]Rgba8)`,`default()`.
- `mapping.zig`—`Mode{linear,log,cyclic}`;`Params{mode,period=default_period(32.0),banded=false}`
  (period cyclic-only,>0;`banded` FLOORS smooth⇒one colour/iteration band);
  `mapToUnit(smooth,max_iter,params)` CLAMPED[0,1);bad→0.
- `iterbuf.zig`—ITERATION only. `iterationBufferLen(vp)`=w*h;`iterateInto(buf,vp,max_iter)`
  PURE(pixel centers;bad `buf.len`→`BufferSizeMismatch`);
  `iterateJuliaInto(buf,vp,c_re,c_im,max_iter)`=Julia twin,pixel=seed z0,c fixed,same contract;
  `iterateRowsInto(buf,vp,max_iter,y0,rows)` band-only/composable,
  overrun→`RowRangeOutOfBounds`;`iterateBandInto(band,…)`=same but buffer-LOCAL(row `y0`
  at index 0=the GPU's contract);`iterate(...)`→`IterationResult{values,elapsed_ns}`.
  `iterateDeepBandInto(band,vp,max_iter,y0,rows,orbit:*const perturb.ReferenceOrbit)`=DEEP
  twin:SAME band-local contract/errors,offsets f64 ONLY(NEVER f128),`perturb.iterateDelta` per
  pixel,SAME sample points as `iterateBandInto`(test-pinned).
- `progressive.zig`—PURE chunk scheduler+upsampler.
  `Pass{rows_total,rows_done,chunk_rows}`:`fraction()`,`done()`,`nextChunk()`(never 0),
  `advance(rows,elapsed_ns)`. `adaptChunkRows(rows,elapsed_ns,target_ns)`→
  `target_chunk_ns`(0.5s budget),≤4×/step,clamped `1..max_chunk_rows`;
  `initial_chunk_rows`=4. `progressLabel(buf[progress_label_buf_len],f)`;`statusControl(rendering,cancelled)`→`StatusControl{cancel,render,none}`,rendering-WINS.
  `upsampleInto(dst,dst_w,dst_h,src,src_w,src_h)`=nearest-neighbour BLOCKY preview.
- `colorpass.zig`—`colorInto(rgba,iter,lut,max_iter,params,interior)` PURE;
  `rgba.len==iter.len*4` checked BEFORE any write;sentinel→`interior`;alpha FORCED 255.
- `engine.zig`—DECOUPLING crux. Owns `view`,`image_side`,`policy`,DERIVED `max_iter`,
  `iter:[]f32`/`rgba:[]u8`,`gradient`+`lut`,`params`,`interior`,`iteration_passes`/`color_passes`.
  `use_gpu`+`gpu_iter_fn:?IterFn(view,w,h,max_iter,y0,rows,band,orbit)`=one BAND/call;
  BOTH backends chunk;a failed band→CPU.`init` does NOT iterate.
  PATH CHOICE HERE:`usesDeepPath()`;`iterate`+`stepPassRows` dispatch via ONE private
  `cpuIterateBand`.`ensureOrbit` builds ONE `ReferenceOrbit` per render(lazy;`orbit_computations`
  counts),`orbitPtr()` borrows it,EVERY boundary(`iterate`,`beginPass`,`cancelPass`,`finishPass`,
  `deinit`)FREES it—never cache.non-null `orbit` OBLIGES backend:iterate DEEP else RETURN
  error(engine warns,CPU finishes).
  `pathSummary(buf)`+`path_summaries`=1/completed render;`IterateError` folds
  `OrbitFailure`→`orbitFailureMessage(buf[orbit_message_buf_len],err,side,max_iter)`.
  `setViewport`/`setPolicy`/`resize` re-iterate(bump BOTH counters);
  `setGradient`/`setMapping`/`setInterior`=color pass ONLY,`iteration_passes` UNCHANGED(GUARANTEE).
  NON-BLOCKING,PREFER:`installView(v)`/`installPolicy(p)` refresh `max_iter`,render NOTHING;
  `beginPass(w,h)` reallocs+seeds BLOCKY preview(`upsampleInto`,else black);`stepPass()`=one
  self-timed chunk(`stepPassRows(rows)` deterministic),`true`=complete→bumps each counter ONCE,
  clears `pass:?progressive.Pass`;`cancelPass()` on input change;`passFraction()→?f32` drives
  progress bar.
- `persist.zig`—pure JSON,NO I/O. `AppState`(centre f128,`side` f64)heap-owns
  `stops`+`mapping_mode`→ALWAYS `freeState(state,alloc)`.
  `fromEngine`→`toJson(buf≥min_json_buf_len)`,`fromJson(json,alloc)`,`applyToEngine`(color setters
  first,`setViewport` LAST). CENTRE=quoted decimal STRING(`writeCenter`=`{d}`=shortest-EXACT,
  `center_text_max_len`;NEVER fixed `.34`=LOSSY<1);PLAIN or e-notation,both EXACT. NO version
  field⇒`CenterJson.jsonParse` IS back-compat:string(M6)OR number(pre-M6),RAW digits→f128,NEVER
  drop branch;bad text→`InvalidField`.
  `ParseError{InvalidJson,MissingField,InvalidField,GradientEmpty,GradientNotSorted}`.
- `scheme.zig`—COLOUR-ONLY save/load,INDEPENDENT of persist,NO view/centre/side/policy.
  `Scheme{stops,mapping_mode,mapping_period,banded,interior_r/g/b/a}`;`SchemeStop{pos,r,g,b,a}`.
  `fromEngine`/`fromJson(json,alloc)` heap-own `stops` ONLY(mapping_mode=static tag)→`free(s,alloc)`;
  `toJson(buf≥min_json_buf_len)`;`applyToEngine`=COLOUR setters ONLY(NEVER `setViewport`).
  `ParseError`+`UnknownMappingMode`.
- `presets.zig`—BUILT-IN colourings(const,binary-baked;NEVER `free`). `Preset{name,scheme}`,
  `all()→[]const Preset`(>1),`gradientOf(p)`→bakeable `Gradient`. `all()[0]`(Classic)pos 0..1⇒LUT=end stops.

## Conventions

Pixel:origin TOP-LEFT,y DOWN,+0.5=center;`im` UP—pixel→complex NEGATES y.
Tests:in-file,one intent each.
