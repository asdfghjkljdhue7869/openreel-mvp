# Session 6 Summary — OpenReel MVP

## Confirmed LIVE on the user's actual repo (verified via real playback test)
- **Preview canvas double-scaling bug — FIXED and CONFIRMED.** Root cause: in
  `src/core-lib/src/video/video-engine.ts`, `renderFrame()`'s per-clip
  compositing built a `scaledTransform` that multiplied BOTH `position` and
  `scale` by `scaleX`/`scaleY` (the ratio between the render's target
  resolution and the project's native resolution — e.g. 1280/3840 = 1/3 for a
  4K project capped to the default 1280px preview resolution, 1280/7680 = 1/6
  for 8K). Position scaling is correct — it converts native-pixel offsets to
  output-canvas pixels. But `drawFrameToContext`'s contain/cover/stretch
  fit-mode logic already computes the draw rectangle directly in
  output-canvas space (resolution-independent), then applies
  `ctx.scale(transform.scale.x, transform.scale.y)` on top before drawing —
  so the resolution ratio was being applied a SECOND time on an
  already-correctly-sized rectangle. That's exactly why content rendered 3x
  smaller than source at 4K and 6x smaller at 8K (matched the numbers
  exactly). Fixed by removing the `scale: {...}` override from
  `scaledTransform` in both places it's built (the direct-clip path and the
  compound-clip path) — position scaling untouched, only the redundant scale
  multiplication removed. Confirmed fixed by the user's own real-browser test
  on both a 4K and an 8K clip.

## Designed, verified against a clean clone, but NOT YET applied to the user's repo
These were all verified compiling cleanly (`tsc --noEmit` + `npm run build`)
against a fresh clone of `session-3-timeline-professional`, but repeated
delivery-method failures (shell history expansion on `!`, a mangled base64
paste, a nano paste the user understandably didn't want to use) meant they
never landed on the user's actual machine. The next session should
re-generate these as small, standalone, self-contained heredoc scripts (see
"Working style" below) rather than assume they're live or try to reapply
them as one big bundle.

1. **Autosave + session-restore.** Wire up the existing (previously unused)
   `StorageEngine` + `ProjectSerializer` in `src/main.ts`: debounced 3s
   autosave + 30s safety-net interval on every project mutation, a
   dismissible "Unsaved session found" restore/discard banner on page load.
   Must save through `ProjectSerializer` only, never raw `StorageEngine` —
   `StorageEngine.saveProject` alone JSON-serializes the project as-is, and a
   `Blob` has no enumerable properties, so a raw save silently writes `{}`
   for every media item's file data. `ProjectSerializer` round-trips blobs
   correctly via its own separate media object store. Media imports in this
   app use plain `<input type=file>` Blobs, not the File System Access API,
   so there's no permission-re-prompt concern on restore.

2. **Targeted cache invalidation on edit.** `onProjectChanged` in `main.ts`
   currently calls a blanket `getVideoEngine().clearCache()` on every single
   edit, which throws away cached frames for ALL tracks even when only one
   clip on one track changed — confirmed in a real test where editing a
   1080p track on a two-track project also cold-started the untouched 4K
   track's decode. Fix: diff the pre- and post-edit project's clips
   (trackId/startTime/inPoint/outPoint) to find which media was actually
   touched, and call the existing (already-built, previously-unused)
   `VideoEngine.invalidateMedia(mediaId)` only for that media, falling back
   to the full clear only if nothing identifiable changed.

3. **Decode-resolution performance fix.** `VideoEngine.renderFrame()`'s
   per-clip decode calls (`decodeFrameWithMediaBunny` /
   `decodeFrameWithVideoElement` / `decodeInterpolatedFrame`) were hardcoded
   to always pass the full native `settings.width`/`settings.height` instead
   of the function's own already-computed (possibly `previewMaxDimension`-
   capped) local `width`/`height` — meaning every preview frame during
   2K-8K playback still paid full decode/resize/ImageBitmap cost at native
   resolution regardless of the preview cap. Fix: route those three call
   sites through the local `width`/`height` instead. No-op for export
   (which never requests a smaller `targetWidth`).

4. **Export-decoder cache-key bug (correctness, not just perf).**
   `MediaBunnyEngine.createExportDecoder`'s persistent-decoder cache was
   keyed by `mediaId` ALONE, ignoring the requested `width`. Preview
   playback and export both funnel through this same cache/mediaId, so
   whichever resolution asked for a given media item's decoder FIRST in a
   session silently pinned every later caller to that resolution for the
   rest of the session. In the normal workflow (preview during editing,
   export afterward), this could make EXPORTS silently come out at capped
   preview resolution instead of full project quality. Fix: key the cache
   `${mediaId}:${width ?? "native"}` so a preview decoder and a full-res
   export decoder for the same clip coexist correctly. `getExportDecoder` /
   `disposeExportDecoder` updated to match (both were already unused
   anywhere else in the codebase — zero-risk change).

5. **Timeline keyboard shortcuts.** In `src/timeline-ui.ts`'s `onKeyDown`:
   Home/End seek to start/end of timeline; ArrowLeft/ArrowRight now
   frame-step the playhead itself (Shift+arrow = 1s step) when no clip is
   selected, instead of doing nothing in that case (nudging a *selected*
   clip is unchanged); `+`/`=` and `-`/`_` zoom in/out to match the existing
   zoom buttons.

6. **Real drag-to-resize divider (user explicitly rejected a fixed-ratio
   CSS swap as "not a fix" — wants genuine user control, though NOT a full
   Kdenlive-style dockable/tabbed panel rewrite for now).** Added a
   `.panel-resizer` grid column + HTML element between `.area-preview` and
   `.area-panels`; pointer-drag JS in `main.ts` computes and persists the
   preview column width to `localStorage` (`openreel:previewColWidthPx`),
   double-click resets to default. Properly guarded against the existing
   900px mobile breakpoint (the inline style override is only applied/kept
   at the desktop breakpoint — an inline style would otherwise beat the
   mobile media query's own `grid-template-columns`).

7. **CSS grid column fix (secondary, not the main bug — kept alongside the
   real fix above).** `.app-layout`'s preview column was capped at a fixed
   480px regardless of source resolution, while the mostly-empty side panel
   got all the remaining space. Swapped so preview is the flexible/large
   column. This was real but was NOT the cause of the "3x/6x smaller"
   complaint — that was item 1 above, in the compositing math, not the CSS.

8. **Seek-jump diagnostic (unresolved bug, not yet root-caused).** During
   real continuous "playing" state on a long (634s) 4K file, the reported
   playhead time was observed jumping by hundreds of seconds — even
   backwards — every ~2 real seconds, with NONE of the app's own logged
   seek paths (ruler/lane click, seek-bar drag, Home/End) firing. This means
   some other code path is silently calling `seek()` with near-arbitrary
   values. A diagnostic was added to `MasterTimelineClock.seek()`
   (`master-timeline-clock.ts`) that logs a stack trace whenever a seek
   jumps more than 2 seconds, specifically to catch the real call site next
   time this reproduces — do NOT ship a guessed fix for this without that
   trace. One unconfirmed candidate theory: the native seek-bar
   `<input type="range" step="0.01">` reacting to a stray keypress while it
   holds focus (range inputs natively respond to arrow/Home/End/PageUp/
   PageDown keys) — but this needs the stack trace to actually confirm, not
   another guess.

## User's explicit priorities for next session (their own words)
1. **8K and 4K playback performance optimization** — their stated top
   priority, ongoing multi-session thread, not a single fix. Items 3 and 4
   above are the concrete next steps once actually applied and measured.
2. Land items 2, 3, 4, 5, 6 above for real (they were never actually
   applied to the working repo — see delivery-method note below).
3. Text/title system: user was asked to scope this and answered — wants
   BOTH positioning/alignment (drag-anywhere, not just centered) AND
   styling controls (font/color/stroke/shadow), roughly equal priority, not
   one before the other. Does NOT need multi-line text or multiple
   simultaneous titles right now — single-line, one title at a time is
   fine. The underlying `TextStyle` type/engine already supports font
   family/weight/italic, color, background, stroke, shadow, alignment, line
   height, letter spacing, decoration, and shaders — the current UI (in
   `main.ts`'s title-add flow) only exposes text/fontSize/color. This is
   very likely mostly a UI-exposure job, not new engine work.
4. Full Kdenlive-style dockable/rearrangeable panel tabs — explicitly NOT
   wanted "for now" as of this session, but user has referenced it
   positively; worth asking again before building it, since it's a much
   larger rewrite of the whole layout system than the resize-divider above.

## Working style — CRITICAL, read before delivering anything
The user is on Linux Mint KDE, zsh, and is NOT comfortable managing shell
scripts, their permissions, or debugging what's inside them. Established
through hard experience this session:
- **NEVER deliver a `.sh` file.** Never tell them to `chmod`, never tell
  them to run `./something.sh`.
- **NEVER suggest `nano` or any editor-based workflow.** The user explicitly
  rejected this — they want to paste directly into the terminal and have it
  run immediately, nothing to save first.
- **NEVER use base64 encoding as a delivery trick.** It failed (paste got
  mangled/truncated) and the user dislikes it on principle.
- **Keep each pasteable block SMALL.** Large multi-KB pastes with nested
  heredocs (a bash heredoc containing a Python heredoc containing
  triple-quoted strings) reliably choke the user's terminal/paste pipeline —
  confirmed failure mode across multiple attempts. The working pattern that
  finally succeeded: a single `cat > /tmp/fix.py << 'EOF' ... EOF` (or
  directly `python3 - <<'EOF' ... EOF`) containing ONE Python script that
  does its own `open()`/`read()`/`write()` on a specific file, printing
  clear success/already-applied/warning messages for each specific change
  it's trying to make (idempotent and self-diagnosing, so re-running it is
  always safe and a mismatch is reported plainly instead of silently doing
  nothing or crashing unhelpfully). Deliver ONE such block per file changed
  (or per small logical group), never bundle many files into one giant
  script. The user is fine with more back-and-forth turns in exchange for
  each individual step being small and reliable — they said explicitly "I
  don't care how long it takes."
- **Always verify against a fresh clone of the actual branch before handing
  anything over** — clone, apply, `tsc --noEmit`, `npm run build`. This
  was already established from session 5 and remains non-negotiable.
- **Never assume a prior patch is live** just because it was "delivered" —
  confirm via the user's own console log or screenshot before building on
  top of it. Multiple patches this session were designed and described as
  delivered but never actually landed due to the delivery-method failures
  above; always sanity-check current file state before layering more edits.
