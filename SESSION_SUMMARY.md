# OpenReel MVP — Session Summary

Snapshot of a stable, verified checkpoint: import → playback → trim →
titles → export, all running on a real fork of the OpenReel Video engine
(`@openreel/core`, extracted standalone from `Augani/openreel-video`).

## What works, confirmed on real hardware (Intel UHD Graphics CML GT2,
Linux, Brave/Flatpak)

- **Import**: fast (~150-700ms even for a 16.5MB/78s file) after disabling
  eager thumbnail + waveform generation, which ran unconditionally by
  default and weren't used by this UI.
- **Playback**: stable, real-time-capable decode for both AVC (~0.3-0.8ms/
  frame) and VP8 (~7-12ms/frame — comfortably under the 16.7ms/60fps
  budget; this is NOT a bottleneck, see "Rejected changes" below).
- **Trim**: in/out points, correctly resets playback state and UI on apply.
- **Titles**: real text overlays via the engine's `titleEngine` + a text
  `Track`, with render caching for static text (animated/keyframed/shader
  titles are deliberately never cached — verified with tests).
- **Export**: produces valid MP4s. ~2x real-time on software encode
  (hardware encode is unreliable on this exact machine — see fixes below).
- **Theming**: whole UI layout is one CSS Grid with named areas, swappable
  by URL (Jellyfin-style), zero inline styles. Default theme is Premiere
  Pro-inspired dark palette, includes a working mobile/touch breakpoint
  example.

## Verified engine fixes made this session (patches in outputs, or apply
directly against `Augani/openreel-video`)

1. **Hardware-encode-with-software-fallback retry** (`export-engine.ts`) —
   export used to hard-crash if hardware encode failed mid-stream (a real,
   reproducible bug on this exact Intel iGPU). Now retries the whole
   export in software once, with the output file properly truncated/reset
   first. 3 new tests.
2. **Playback drift-deadlock fix** (`playback-controller.ts`) — a single
   slow frame during real-time playback could permanently freeze video
   forever (drift, once above threshold, could never recalculate since
   the "skip" path never rendered again). Fixed to always render and
   recover. This module had zero prior test coverage; added 2 tests plus
   a from-scratch Node/AudioContext test harness for it.
3. **Decode fallback timeout reduced 10s → 2s** (`video-engine.ts`) — a
   failed decode's last-resort `<video>` element fallback could freeze
   the whole page for 10 real seconds before giving up.
4. **Decode session reuse — the big one** (`video-engine.ts`) — playback
   was tearing down and rebuilding the entire demuxer/decoder from
   scratch on EVERY SINGLE FRAME (`getFrameAtTime`), instead of using the
   persistent sequential decoder session (`ExportFrameDecoder`) that
   already existed but was only wired up for export. This was the actual
   cause of "fps is trash" / wildly swinging frame times — not hardware
   weakness. Real-world result: avgFrameRenderTime dropped from ~50-80ms
   to ~0.3-0.8ms on the test AVC file. 3 new tests.
5. **Preview resolution cap** (`playback-controller.ts` /
   `playback/types.ts`) — realtime preview now caps at 1280px on the long
   edge by default (`previewMaxDimension`, configurable/disable-able).
   Sources at/below the cap are untouched. Export is completely
   unaffected — always renders at full project resolution. This is
   forward-looking: matters once 4K/8K sources are imported, not visible
   on today's 720p/1080p test files. 4 new tests.
6. **Text render caching** (`title-engine.ts`) — `renderText()` allocated
   a full-resolution `OffscreenCanvas` and redid text layout via
   `fillText()` on every single frame. Static text (no animation,
   keyframes, or shader — all individually checked) is now cached and
   reused; time-varying titles are deliberately never cached, verified by
   8 tests specifically checking each animation type still re-renders.

All of the above: full 148-file / 1214-test suite passes with zero
regressions after each change, checked every time.

## Rejected change — important context for future-you

Tried forcing `hardwareAcceleration: 'prefer-hardware'` on VP8 decode
(`CanvasSink`/`ExportFrameDecoder` in `mediabunny-engine.ts`) to close the
gap with AVC's much faster decode. **This was wrong and made things
dramatically worse**: avgFrameRenderTime went from ~7ms to 47-70ms,
dropped frames climbed continuously, and export nearly crashed the tab.
Fully reverted. Mediabunny's own docs explicitly warn hardware
acceleration is "best left on `no-preference`" — and this exact machine
already had a separate, confirmed case of forced hardware preference
causing real encode failures. **Do not re-attempt this without concrete
profiling data showing decode is an actual bottleneck** — 7-12ms/frame is
not one; it's comfortably real-time.

## Known open issues, not yet fixed

- **A real hang** was observed once on the VP8/webm file at a specific
  trim range (30-50s): `avgFrameRenderTime` froze at an exact value
  (9484.7ms) across multiple stats snapshots — a genuine stuck render,
  not the drift-skip pattern (already fixed). Not reproduced again since;
  narrow repro conditions, needs a DevTools console check next time it
  happens to get a real stack/error.
- **Titles scheduled outside a timeline's range after a trim** silently
  never show, with no warning. The title's `startTime` is timeline-
  relative and doesn't get repositioned or validated against a new
  (shorter) duration after trimming.
- **A recurring resource leak**: `console.error: "A VideoSample was
  garbage collected without first being closed"` appears repeatedly
  during real use (import/export cycles). Not yet root-caused or fixed.
  Suspected (not confirmed) to be a contributing factor in a separate
  observed issue: GPU process crashes and export completely failing to
  progress after a long session — see `openreel-core`'s
  `HARDWARE_NOTES.md` for the full writeup.
- **Multi-clip/multi-track timeline UI** — the whole app currently
  supports exactly one clip on one video track. This is the natural next
  big feature.

## Project structure

- `openreel-mvp/` (this repo) — the actual Vite + vanilla TS app
  (`src/main.ts`, `src/index.html`, `src/theme-default.css`).
- **The engine now lives in its own separate repo**, `openreel-core`, so
  it's usable independently by anyone who just wants the engine (timeline,
  compositor, export) without this app or the rest of the upstream
  monorepo. See that repo's `README.md` and `HARDWARE_NOTES.md` for full
  details on the fixes and the hardware/driver diagnostic findings from
  this session (Gen 9.5 Intel iGPU specifics, Mesa/VAAPI/Vulkan behavior,
  the Brave version regression, etc.).
- This app currently still bundles its own copy of the engine under
  `src/core-lib/` for a simple, dependency-free build — sync any future
  engine fixes from `openreel-core` into `src/core-lib/` by hand, or
  switch this app to depend on `openreel-core` as a real package if you
  want single-source-of-truth going forward.
