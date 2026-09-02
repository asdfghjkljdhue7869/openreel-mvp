#!/usr/bin/env bash
set -euo pipefail

FILE="src/main.ts"

if [ ! -f "$FILE" ]; then
  echo "ERROR: $FILE not found. Run this from the openreel-mvp repo root." >&2
  exit 1
fi

if grep -q "generateWaveformForMedia" "$FILE"; then
  echo "ERROR: generateWaveformForMedia already referenced in $FILE — patch looks already applied, aborting to avoid double-patching." >&2
  exit 1
fi

python3 - "$FILE" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    src = f.read()

# --- Path 1: import onto an existing track ---
track_import_old = """      const result = await importService.importMedia(file, {
        generateThumbnails: false,
        generateWaveform: true,
      });
      if (!result.success || !result.media) {
        log(`Import failed: ${result.error ?? "unknown error"}`);
        return;
      }

      const mediaItem = importService.processedMediaToMediaItem(result.media);
      const clipDuration = result.media.metadata.duration;

      // Re-read the current track from the latest project (it may have
      // shifted since the picker opened, e.g. a drag committed meanwhile)
      // and append after whatever's already on it rather than overlapping at 0.
      const currentTrack = project.timeline.tracks.find((t) => t.id === trackId);
      if (!currentTrack) {
        log(`Track no longer exists — clip not added.`);
        return;
      }
      const lastEnd = currentTrack.clips.reduce(
        (max, c) => Math.max(max, c.startTime + c.duration),
        0,
      );

      // Add the media item to the library first — clip/add looks it up by
      // id to compute the new clip's duration/inPoint/outPoint — then let
      // the action executor add the actual clip so it's undoable.
      project = {
        ...project,
        modifiedAt: Date.now(),
        mediaLibrary: { items: [...project.mediaLibrary.items, mediaItem] },
      };
      await timelineUI.addClipToTrack(project, trackId, mediaItem.id, lastEnd, clipDuration);

      playback?.setProject(project);
      log(
        `Added "${file.name}" to "${targetTrack.name}" at ${lastEnd.toFixed(2)}s (duration ${clipDuration.toFixed(2)}s).`,
      );
    } catch (e) {
      log(`Error importing clip: ${e instanceof Error ? e.message : String(e)}`);
    }
  });"""

track_import_new = """      const result = await importService.importMedia(file, {
        generateThumbnails: false,
        generateWaveform: false,
      });
      if (!result.success || !result.media) {
        log(`Import failed: ${result.error ?? "unknown error"}`);
        return;
      }

      const mediaItem = importService.processedMediaToMediaItem(result.media);
      const clipDuration = result.media.metadata.duration;

      // Re-read the current track from the latest project (it may have
      // shifted since the picker opened, e.g. a drag committed meanwhile)
      // and append after whatever's already on it rather than overlapping at 0.
      const currentTrack = project.timeline.tracks.find((t) => t.id === trackId);
      if (!currentTrack) {
        log(`Track no longer exists — clip not added.`);
        return;
      }
      const lastEnd = currentTrack.clips.reduce(
        (max, c) => Math.max(max, c.startTime + c.duration),
        0,
      );

      // Add the media item to the library first — clip/add looks it up by
      // id to compute the new clip's duration/inPoint/outPoint — then let
      // the action executor add the actual clip so it's undoable.
      project = {
        ...project,
        modifiedAt: Date.now(),
        mediaLibrary: { items: [...project.mediaLibrary.items, mediaItem] },
      };
      await timelineUI.addClipToTrack(project, trackId, mediaItem.id, lastEnd, clipDuration);

      playback?.setProject(project);
      log(
        `Added "${file.name}" to "${targetTrack.name}" at ${lastEnd.toFixed(2)}s (duration ${clipDuration.toFixed(2)}s).`,
      );

      // Waveform analysis scans the whole file and used to run inline
      // above (generateWaveform: true), blocking this handler on every
      // import. Run it in the background instead so import stays fast,
      // and only apply the result if this media item is still around by
      // the time it finishes (a later import could have replaced it).
      const waveformMediaId = mediaItem.id;
      importService
        .generateWaveformForMedia(file, 100)
        .then((waveform) => {
          if (!waveform || !project) return;
          if (!project.mediaLibrary.items.some((item) => item.id === waveformMediaId)) return;
          project = {
            ...project,
            mediaLibrary: {
              items: project.mediaLibrary.items.map((item) =>
                item.id === waveformMediaId ? { ...item, waveformData: waveform.peaks } : item,
              ),
            },
          };
          timelineUI.setProject(project);
        })
        .catch((e) => {
          log(`Waveform generation failed (clip plays fine, just no waveform): ${e instanceof Error ? e.message : String(e)}`);
        });
    } catch (e) {
      log(`Error importing clip: ${e instanceof Error ? e.message : String(e)}`);
    }
  });"""

if src.count(track_import_old) != 1:
    print(f"ERROR: track-import anchor found {src.count(track_import_old)} time(s), expected exactly 1 — aborting.", file=sys.stderr)
    sys.exit(1)
src = src.replace(track_import_old, track_import_new, 1)

# --- Path 2: primary file-input import (new project) ---
main_import_old = """    // Thumbnails aren't shown anywhere in this UI yet, so those stay off —
    // but the timeline now renders a waveform on every clip, so waveform
    // analysis (100 samples/sec across the file) needs to run at import
    // time. This does add real time on longer files.
    const importStart = performance.now();
    const result = await importService.importMedia(file, {
      generateThumbnails: false,
      generateWaveform: true,
    });"""

main_import_new = """    // Thumbnails aren't shown anywhere in this UI yet, so those stay off.
    // Waveform analysis also stays off here — it scans the whole file and
    // used to run inline, blocking this handler on every import. It's
    // kicked off in the background further below instead, once import
    // itself has already finished and the clip is usable.
    const importStart = performance.now();
    const result = await importService.importMedia(file, {
      generateThumbnails: false,
      generateWaveform: false,
    });"""

if src.count(main_import_old) != 1:
    print(f"ERROR: main-import anchor found {src.count(main_import_old)} time(s), expected exactly 1 — aborting.", file=sys.stderr)
    sys.exit(1)
src = src.replace(main_import_old, main_import_new, 1)

background_hook_old = """    setStatus("Ready", "done");
    log("Timeline built: 1 track, 1 clip. Ready to play, trim, and export.");

    cancelAnimationFrame(rafHandle);
    tickTimeDisplay();"""

background_hook_new = """    setStatus("Ready", "done");
    log("Timeline built: 1 track, 1 clip. Ready to play, trim, and export.");

    const waveformMediaId = mediaId;
    importService
      .generateWaveformForMedia(file, 100)
      .then((waveform) => {
        if (!waveform || !project) return;
        if (!project.mediaLibrary.items.some((item) => item.id === waveformMediaId)) return;
        project = {
          ...project,
          mediaLibrary: {
            items: project.mediaLibrary.items.map((item) =>
              item.id === waveformMediaId ? { ...item, waveformData: waveform.peaks } : item,
            ),
          },
        };
        timelineUI.setProject(project);
        log("Waveform ready.");
      })
      .catch((e) => {
        log(`Waveform generation failed (clip plays fine, just no waveform): ${e instanceof Error ? e.message : String(e)}`);
      });

    cancelAnimationFrame(rafHandle);
    tickTimeDisplay();"""

if src.count(background_hook_old) != 1:
    print(f"ERROR: background-hook anchor found {src.count(background_hook_old)} time(s), expected exactly 1 — aborting.", file=sys.stderr)
    sys.exit(1)
src = src.replace(background_hook_old, background_hook_new, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(src)

print("Patched both import paths: waveform generation now runs in the background after import instead of blocking it.")
PYEOF

if [ "$(grep -c "generateWaveformForMedia" "$FILE")" -ne 2 ]; then
  echo "ERROR: expected 2 calls to generateWaveformForMedia (one per import path), found $(grep -c "generateWaveformForMedia" "$FILE"). Check $FILE manually." >&2
  exit 1
fi
if [ "$(grep -c "generateWaveform: true,$" "$FILE")" -ne 0 ]; then
  echo "ERROR: generateWaveform: true still present somewhere — patch did not fully apply. Check $FILE manually." >&2
  exit 1
fi

echo ""
echo "Patched $FILE successfully:"
echo "  - both import paths now skip waveform analysis during import itself"
echo "  - waveform is generated in the background afterward and applied (with a re-render) once ready"
echo "  - import should feel instant again; the waveform will visibly pop in a moment later on longer files"
echo ""
echo "Run your test suite now:"
echo "  npm test"
