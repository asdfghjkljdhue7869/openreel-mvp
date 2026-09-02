#!/usr/bin/env bash
set -euo pipefail

FILE="src/main.ts"

if [ ! -f "$FILE" ]; then
  echo "ERROR: $FILE not found. Run this from the openreel-mvp repo root." >&2
  exit 1
fi

if grep -q "calculateProjectDuration" "$FILE"; then
  echo "ERROR: calculateProjectDuration already referenced in $FILE — patch looks already applied, aborting to avoid double-patching." >&2
  exit 1
fi

python3 - "$FILE" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    src = f.read()

import_old = """import {
  getMediaImportService,
  createTrack,
  createClip,
  type Project,
  type Track,
  type Clip,
} from "@openreel/core";"""
import_new = """import {
  getMediaImportService,
  createTrack,
  createClip,
  calculateProjectDuration,
  type Project,
  type Track,
  type Clip,
} from "@openreel/core";"""

if src.count(import_old) != 1:
    print(f"ERROR: import-block anchor found {src.count(import_old)} time(s), expected exactly 1 — aborting.", file=sys.stderr)
    sys.exit(1)
src = src.replace(import_old, import_new, 1)

handlers_old = """    onAddTitle: ({ trackId, text, fontSize, color, start, duration }) => {
      if (!project) return;
      const textClip = titleEngine.createTextClip({
        trackId,
        startTime: start,
        duration,
        text,
        style: { ...DEFAULT_TEXT_STYLE, fontSize, color },
      });
      playback?.setProject(project);
      refreshTextClips();
      log(`Title added: "${text}" at ${start.toFixed(2)}s for ${duration.toFixed(2)}s (clip id ${textClip.id}).`);
    },
    onUpdateTextClip: (id, updates) => {
      const updated = titleEngine.updateTextClip(id, updates);
      if (!project || !updated) return;
      playback?.setProject(project);
      refreshTextClips();
    },
    onDeleteTitle: (id) => {
      titleEngine.deleteTextClip(id);
      if (project) playback?.setProject(project);
      refreshTextClips();
      log(`Title ${id} deleted.`);
    },"""

handlers_new = """    onAddTitle: ({ trackId, text, fontSize, color, start, duration }) => {
      if (!project) return;
      const textClip = titleEngine.createTextClip({
        trackId,
        startTime: start,
        duration,
        text,
        style: { ...DEFAULT_TEXT_STYLE, fontSize, color },
      });
      // Titles live in titleEngine, not project.timeline.tracks, so the
      // executor-driven duration recompute never sees them. Sync them into
      // project.textClips and recompute here too, or a trailing title never
      // extends the seek bar / transport duration past the last video clip.
      project = { ...project, textClips: titleEngine.getAllTextClips() };
      project = { ...project, timeline: { ...project.timeline, duration: calculateProjectDuration(project) } };
      sourceDuration = project.timeline.duration;
      seekBar.max = String(sourceDuration);
      playback?.setProject(project);
      refreshTextClips();
      log(`Title added: "${text}" at ${start.toFixed(2)}s for ${duration.toFixed(2)}s (clip id ${textClip.id}).`);
    },
    onUpdateTextClip: (id, updates) => {
      const updated = titleEngine.updateTextClip(id, updates);
      if (!project || !updated) return;
      project = { ...project, textClips: titleEngine.getAllTextClips() };
      project = { ...project, timeline: { ...project.timeline, duration: calculateProjectDuration(project) } };
      sourceDuration = project.timeline.duration;
      seekBar.max = String(sourceDuration);
      playback?.setProject(project);
      refreshTextClips();
      log(
        `[timeline] Title ${id} updated: start=${updated.startTime.toFixed(2)}s duration=${updated.duration.toFixed(2)}s`,
      );
    },
    onDeleteTitle: (id) => {
      titleEngine.deleteTextClip(id);
      if (project) {
        project = { ...project, textClips: titleEngine.getAllTextClips() };
        project = { ...project, timeline: { ...project.timeline, duration: calculateProjectDuration(project) } };
        sourceDuration = project.timeline.duration;
        seekBar.max = String(sourceDuration);
        playback?.setProject(project);
      }
      refreshTextClips();
      log(`Title ${id} deleted.`);
    },"""

if src.count(handlers_old) != 1:
    print(f"ERROR: title-handlers anchor found {src.count(handlers_old)} time(s), expected exactly 1 — aborting.", file=sys.stderr)
    sys.exit(1)
src = src.replace(handlers_old, handlers_new, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(src)

print("Patched import block and all three title callback handlers.")
PYEOF

if [ "$(grep -c "calculateProjectDuration" "$FILE")" -ne 4 ]; then
  echo "ERROR: expected 4 references to calculateProjectDuration (1 import + 3 calls), found $(grep -c "calculateProjectDuration" "$FILE"). Check $FILE manually." >&2
  exit 1
fi

if [ "$(grep -c "\[timeline\] Title" "$FILE")" -ne 1 ]; then
  echo "ERROR: expected the new title-update log line, not found. Check $FILE manually." >&2
  exit 1
fi

echo ""
echo "Patched $FILE successfully:"
echo "  - titles now sync into project.textClips and recompute project.timeline.duration on add/update/delete"
echo "  - seek bar / time label now stay correct when a title extends past the last video clip"
echo "  - title drag/resize now logs '[timeline] Title <id> updated: start=... duration=...' so a future mismatch can be diagnosed from the log"
echo ""
echo "Run your test suite now:"
echo "  npm test"
