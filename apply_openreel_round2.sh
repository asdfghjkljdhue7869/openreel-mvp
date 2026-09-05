set -euo pipefail

for f in src/theme-default.css src/core-lib/src/video/video-engine.ts src/core-lib/src/media/mediabunny-engine.ts src/timeline-ui.ts src/main.ts; do
  if [ ! -f "$f" ]; then
    echo "ERROR: $f not found. Run this from the openreel-mvp repo root." >&2
    exit 1
  fi
done

python3 - src/theme-default.css <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    src = f.read()

old1 = """.app-layout {
  display: grid;
  gap: 16px;
  width: 100%;
  grid-template-columns: minmax(320px, 480px) 1fr;
  grid-template-areas:
    "header   header"
    "preview  panels"
    "actions  actions"
    "timeline timeline"
    "log      log";
}"""
new1 = """.app-layout {
  display: grid;
  gap: 16px;
  width: 100%;
  grid-template-columns: minmax(480px, 1fr) minmax(280px, 360px);
  grid-template-areas:
    "header   header"
    "preview  panels"
    "actions  actions"
    "timeline timeline"
    "log      log";
}"""
if src.count(old1) != 1:
    sys.exit(f"ERROR: .app-layout anchor found {src.count(old1)} time(s) in {path}, expected 1")
src = src.replace(old1, new1, 1)

old2 = """#canvas {
  background: black;
  border: 1px solid var(--border);
  display: block;
  margin: 10px 0;
  width: 100%;
  height: auto;
}"""
new2 = """#canvas {
  background: black;
  border: 1px solid var(--border);
  display: block;
  margin: 10px 0;
  width: 100%;
  max-width: 1600px;
  height: auto;
}"""
if src.count(old2) != 1:
    sys.exit(f"ERROR: #canvas anchor found {src.count(old2)} time(s) in {path}, expected 1")
src = src.replace(old2, new2, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(src)
print(f"Patched {path}: preview column now flexible, panels column capped, canvas max-width added.")
PYEOF

python3 - src/core-lib/src/video/video-engine.ts <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    src = f.read()

old = """            if (shouldInterpolate && mediaItem.metadata?.frameRate) {
              bitmap = await this.decodeInterpolatedFrame(
                clip,
                mediaItem,
                clipInfo.sourceTime,
                time,
                settings.width,
                settings.height,
              );
            }

            if (!bitmap) {
              const vidstabForDecode = getVidstabEngine();
              const useStabilizedBlob = vidstabForDecode.hasStabilized(clip.id);
              const decodeBlob = useStabilizedBlob
                ? vidstabForDecode.getStabilizedBlob(clip.id)!
                : mediaItem.blob;
              const decodeTime = useStabilizedBlob
                ? clipInfo.sourceTime - clip.inPoint
                : clipInfo.sourceTime;

              bitmap = await this.decodeFrameWithMediaBunny(
                decodeBlob,
                decodeTime,
                settings.width,
                settings.height,
                useStabilizedBlob ? `stabilized:${clip.id}` : clipInfo.mediaId,
              );
            }
            if (!bitmap) {
              const vidstabForDecode = getVidstabEngine();
              const useStabilizedBlob = vidstabForDecode.hasStabilized(clip.id);
              const decodeBlob = useStabilizedBlob
                ? vidstabForDecode.getStabilizedBlob(clip.id)!
                : mediaItem.blob;
              const decodeTime = useStabilizedBlob
                ? clipInfo.sourceTime - clip.inPoint
                : clipInfo.sourceTime;

              bitmap = await this.decodeFrameWithVideoElement(
                useStabilizedBlob ? `stabilized:${clip.id}` : mediaItem.id,
                decodeBlob,
                decodeTime,
                settings.width,
                settings.height,
              );
            }
          }"""
new = """            if (shouldInterpolate && mediaItem.metadata?.frameRate) {
              bitmap = await this.decodeInterpolatedFrame(
                clip,
                mediaItem,
                clipInfo.sourceTime,
                time,
                width,
                height,
              );
            }

            if (!bitmap) {
              const vidstabForDecode = getVidstabEngine();
              const useStabilizedBlob = vidstabForDecode.hasStabilized(clip.id);
              const decodeBlob = useStabilizedBlob
                ? vidstabForDecode.getStabilizedBlob(clip.id)!
                : mediaItem.blob;
              const decodeTime = useStabilizedBlob
                ? clipInfo.sourceTime - clip.inPoint
                : clipInfo.sourceTime;

              bitmap = await this.decodeFrameWithMediaBunny(
                decodeBlob,
                decodeTime,
                width,
                height,
                useStabilizedBlob ? `stabilized:${clip.id}` : clipInfo.mediaId,
              );
            }
            if (!bitmap) {
              const vidstabForDecode = getVidstabEngine();
              const useStabilizedBlob = vidstabForDecode.hasStabilized(clip.id);
              const decodeBlob = useStabilizedBlob
                ? vidstabForDecode.getStabilizedBlob(clip.id)!
                : mediaItem.blob;
              const decodeTime = useStabilizedBlob
                ? clipInfo.sourceTime - clip.inPoint
                : clipInfo.sourceTime;

              bitmap = await this.decodeFrameWithVideoElement(
                useStabilizedBlob ? `stabilized:${clip.id}` : mediaItem.id,
                decodeBlob,
                decodeTime,
                width,
                height,
              );
            }
          }"""
if src.count(old) != 1:
    sys.exit(f"ERROR: decode-call anchor found {src.count(old)} time(s) in {path}, expected 1")
src = src.replace(old, new, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(src)
print(f"Patched {path}: per-clip decode now targets the render's actual output resolution instead of always native.")
PYEOF

python3 - src/core-lib/src/media/mediabunny-engine.ts <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    src = f.read()

old = """  async createExportDecoder(mediaId: string, file: File | Blob, width?: number): Promise<ExportFrameDecoder | null> {
    this.ensureInitialized();

    const existing = this.exportDecoders.get(mediaId);
    if (existing) {
      return existing;
    }

    const decoder = new ExportFrameDecoder(this.mediabunny!, file, width);
    const success = await decoder.initialize();
    if (!success) {
      return null;
    }

    this.exportDecoders.set(mediaId, decoder);
    return decoder;
  }

  getExportDecoder(mediaId: string): ExportFrameDecoder | null {
    return this.exportDecoders.get(mediaId) || null;
  }

  disposeExportDecoder(mediaId: string): void {
    const decoder = this.exportDecoders.get(mediaId);
    if (decoder) {
      decoder.dispose();
      this.exportDecoders.delete(mediaId);
    }
  }"""
new = """  async createExportDecoder(mediaId: string, file: File | Blob, width?: number): Promise<ExportFrameDecoder | null> {
    this.ensureInitialized();

    // Keyed by mediaId+width, not mediaId alone: preview playback and
    // export both call this with the same mediaId but different widths
    // (preview is capped, export wants native resolution). Caching by
    // mediaId alone meant whichever one ran first pinned the other to its
    // resolution for the rest of the session.
    const cacheKey = `${mediaId}:${width ?? "native"}`;
    const existing = this.exportDecoders.get(cacheKey);
    if (existing) {
      return existing;
    }

    const decoder = new ExportFrameDecoder(this.mediabunny!, file, width);
    const success = await decoder.initialize();
    if (!success) {
      return null;
    }

    this.exportDecoders.set(cacheKey, decoder);
    return decoder;
  }

  getExportDecoder(mediaId: string, width?: number): ExportFrameDecoder | null {
    return this.exportDecoders.get(`${mediaId}:${width ?? "native"}`) || null;
  }

  disposeExportDecoder(mediaId: string, width?: number): void {
    const cacheKey = `${mediaId}:${width ?? "native"}`;
    const decoder = this.exportDecoders.get(cacheKey);
    if (decoder) {
      decoder.dispose();
      this.exportDecoders.delete(cacheKey);
    }
  }"""
if src.count(old) != 1:
    sys.exit(f"ERROR: exportDecoders cache anchor found {src.count(old)} time(s) in {path}, expected 1")
src = src.replace(old, new, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(src)
print(f"Patched {path}: export decoder cache now keyed by mediaId+width.")
PYEOF

python3 - src/timeline-ui.ts <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    src = f.read()

old = """      case "ArrowLeft":
      case "ArrowRight": {
        if (!this.selectedClipId) return;
        e.preventDefault();
        const frameRate = this.project?.settings.frameRate || 30;
        const step = e.shiftKey ? 1 : 1 / frameRate;
        const delta = e.key === "ArrowLeft" ? -step : step;
        this.nudgeSelected(delta);
        return;
      }
    }
  }"""
new = """      case "ArrowLeft":
      case "ArrowRight": {
        e.preventDefault();
        const frameRate = this.project?.settings.frameRate || 30;
        const step = e.shiftKey ? 1 : 1 / frameRate;
        const delta = e.key === "ArrowLeft" ? -step : step;
        if (this.selectedClipId) {
          this.nudgeSelected(delta);
        } else {
          this.callbacks.onSeek(Math.max(0, this.currentTime + delta));
        }
        return;
      }
      case "Home":
        e.preventDefault();
        this.callbacks.onSeek(0);
        return;
      case "End": {
        e.preventDefault();
        this.callbacks.onSeek(this.project?.timeline.duration ?? 0);
        return;
      }
      case "+":
      case "=":
        e.preventDefault();
        this.setZoom(this.pixelsPerSecond + 20);
        return;
      case "-":
      case "_":
        e.preventDefault();
        this.setZoom(this.pixelsPerSecond - 20);
        return;
    }
  }"""
if src.count(old) != 1:
    sys.exit(f"ERROR: onKeyDown ArrowLeft/ArrowRight anchor found {src.count(old)} time(s) in {path}, expected 1")
src = src.replace(old, new, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(src)
print(f"Patched {path}: added Home/End/playhead-arrow-step/+/- zoom shortcuts.")
PYEOF

python3 - src/main.ts <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    src = f.read()

def apply(old, new, label):
    global src
    n = src.count(old)
    if n != 1:
        sys.exit(f"ERROR: anchor for '{label}' found {n} time(s), expected 1")
    src = src.replace(old, new, 1)

apply(
"""import {
  getMediaImportService,
  createTrack,
  createClip,
  calculateProjectDuration,
  type Project,
  type Track,
  type Clip,
} from "@openreel/core";""",
"""import {
  getMediaImportService,
  createTrack,
  createClip,
  calculateProjectDuration,
  createStorageEngine,
  createProjectSerializer,
  type Project,
  type Track,
  type Clip,
} from "@openreel/core";""",
"imports",
)

apply(
"""let textTrack: Track | null = null;

let project: Project | null = null;
let track: Track | null = null;
let clip: Clip | null = null;
let mediaId: string | null = null;
let sourceDuration = 0;
let playback: PlaybackController | null = null;
let rafHandle = 0;""",
"""let textTrack: Track | null = null;

let project: Project | null = null;
let track: Track | null = null;
let clip: Clip | null = null;
let mediaId: string | null = null;
let sourceDuration = 0;
let playback: PlaybackController | null = null;
let rafHandle = 0;

const storageEngine = createStorageEngine();
const projectSerializer = createProjectSerializer(storageEngine);
const AUTOSAVE_DEBOUNCE_MS = 3000;
const AUTOSAVE_SAFETY_INTERVAL_MS = 30000;
let autosaveTimer: ReturnType<typeof setTimeout> | null = null;

async function persistProjectNow(): Promise<void> {
  if (!project) return;
  try {
    await projectSerializer.saveProject(project);
    log(`[autosave] Saved (${project.mediaLibrary.items.length} media item(s), ${project.timeline.tracks.length} track(s)).`);
  } catch (e) {
    log(`[autosave] Save failed: ${e instanceof Error ? e.message : String(e)}`);
  }
}

function scheduleAutosave(): void {
  if (!project) return;
  if (autosaveTimer) clearTimeout(autosaveTimer);
  autosaveTimer = setTimeout(() => {
    autosaveTimer = null;
    void persistProjectNow();
  }, AUTOSAVE_DEBOUNCE_MS);
}

setInterval(() => {
  if (project) void persistProjectNow();
}, AUTOSAVE_SAFETY_INTERVAL_MS);

function dismissRestoreBanner(): void {
  document.getElementById("autosaveRestoreBanner")?.remove();
}

function showRestoreBanner(summary: { id: string; name: string; modifiedAt: number }): void {
  dismissRestoreBanner();
  const banner = document.createElement("div");
  banner.id = "autosaveRestoreBanner";
  banner.style.cssText =
    "background:#2a2a2a;border:1px solid #555;border-radius:4px;padding:10px 14px;margin:0 0 12px 0;display:flex;gap:12px;align-items:center;flex-wrap:wrap;";
  const label = document.createElement("span");
  label.textContent = `Unsaved session found: "${summary.name}" (saved ${new Date(summary.modifiedAt).toLocaleString()}).`;
  label.style.flex = "1 1 auto";
  const restoreBtn = document.createElement("button");
  restoreBtn.textContent = "Restore";
  restoreBtn.className = "touch-target primary";
  restoreBtn.addEventListener("click", () => {
    dismissRestoreBanner();
    void restoreProject(summary.id);
  });
  const discardBtn = document.createElement("button");
  discardBtn.textContent = "Discard";
  discardBtn.className = "touch-target";
  discardBtn.addEventListener("click", () => {
    dismissRestoreBanner();
    void storageEngine.deleteProject(summary.id).catch(() => {});
    log("[autosave] Discarded saved session.");
  });
  banner.append(label, restoreBtn, discardBtn);
  const previewSection = document.querySelector(".area-preview");
  previewSection?.insertBefore(banner, previewSection.firstChild);
}

async function checkForAutosavedProject(): Promise<void> {
  try {
    const summaries = await storageEngine.listProjects();
    if (summaries.length === 0) return;
    showRestoreBanner(summaries[0]);
  } catch (e) {
    log(`[autosave] Could not check for a saved session: ${e instanceof Error ? e.message : String(e)}`);
  }
}

async function restoreProject(id: string): Promise<void> {
  setStatus("Restoring session…", "working");
  try {
    const restored = await projectSerializer.loadProject(id);
    if (!restored) {
      log(`[autosave] Saved session ${id} could not be loaded (missing or corrupt).`);
      setStatus("Waiting for a video…", "idle");
      return;
    }

    const missingBlobs = restored.mediaLibrary.items.filter((item) => !item.blob).length;
    if (missingBlobs > 0) {
      log(`[autosave] Warning: ${missingBlobs} media item(s) restored without their file data — re-import them if playback looks wrong.`);
    }

    project = restored;
    track = null;
    clip = null;
    textTrack = restored.timeline.tracks.find((t) => t.type === "text") ?? null;
    mediaId = restored.mediaLibrary.items[0]?.id ?? null;
    sourceDuration = restored.timeline.duration;

    if (!playback) await setupPlayback();
    playback!.setProject(restored);
    timelineUI.setProject(restored);
    titleEngine.initialize(restored.settings.width, restored.settings.height);
    titleEngine.loadTextClips(restored.textClips ?? []);
    refreshTextClips();

    canvas.width = restored.settings.width;
    canvas.height = restored.settings.height;
    playback!.setDisplayCanvas(canvas);

    seekBar.max = String(sourceDuration);
    seekBar.disabled = false;
    playBtn.disabled = false;
    exportBtn.disabled = false;

    await playback!.seek(0);
    setStatus("Ready", "done");
    log(`[autosave] Restored session "${restored.name}" (${restored.mediaLibrary.items.length} media item(s)).`);
  } catch (e) {
    setStatus("Error", "error");
    log(`[autosave] Restore failed: ${e instanceof Error ? e.message : String(e)}`);
  }
}""",
"autosave core + restore banner",
)

apply(
"""      sourceDuration = updatedProject.timeline.duration;
      seekBar.max = String(sourceDuration);
      // The video engine's frame cache is keyed independently of the
      // timeline's clip data — an edit (trim/split/move) doesn't tell it
      // anything changed, so it can keep serving stale pre-edit frames
      // until they age out naturally. Clear it on every edit, same as
      // what already happens on a fresh import, so playback reflects the
      // edit immediately instead of needing a few play/pause cycles.
      try {
        getVideoEngine().clearCache();
      } catch {
        // Not initialized yet — nothing to clear.
      }
    },""",
"""      sourceDuration = updatedProject.timeline.duration;
      seekBar.max = String(sourceDuration);
      // The video engine's frame cache is keyed independently of the
      // timeline's clip data — an edit (trim/split/move) doesn't tell it
      // anything changed, so it can keep serving stale pre-edit frames
      // until they age out naturally. Clear it on every edit, same as
      // what already happens on a fresh import, so playback reflects the
      // edit immediately instead of needing a few play/pause cycles.
      try {
        getVideoEngine().clearCache();
      } catch {
        // Not initialized yet — nothing to clear.
      }
      scheduleAutosave();
    },""",
"onProjectChanged autosave hook",
)

apply(
"""      playback?.setProject(project);
      refreshTextClips();
      log(`Title added: "${text}" at ${start.toFixed(2)}s for ${duration.toFixed(2)}s (clip id ${textClip.id}).`);
    },""",
"""      playback?.setProject(project);
      refreshTextClips();
      scheduleAutosave();
      log(`Title added: "${text}" at ${start.toFixed(2)}s for ${duration.toFixed(2)}s (clip id ${textClip.id}).`);
    },""",
"onAddTitle autosave hook",
)

apply(
"""      playback?.setProject(project);
      refreshTextClips();
      log(
        `[timeline] Title ${id} updated: start=${updated.startTime.toFixed(2)}s duration=${updated.duration.toFixed(2)}s`,
      );
    },""",
"""      playback?.setProject(project);
      refreshTextClips();
      scheduleAutosave();
      log(
        `[timeline] Title ${id} updated: start=${updated.startTime.toFixed(2)}s duration=${updated.duration.toFixed(2)}s`,
      );
    },""",
"onUpdateTextClip autosave hook",
)

apply(
"""      refreshTextClips();
      log(`Title ${id} deleted.`);
    },""",
"""      refreshTextClips();
      scheduleAutosave();
      log(`Title ${id} deleted.`);
    },""",
"onDeleteTitle autosave hook",
)

apply(
"""      await timelineUI.addClipToTrack(project, trackId, mediaItem.id, lastEnd, clipDuration);

      playback?.setProject(project);
      log(
        `Added "${file.name}" to "${targetTrack.name}" at ${lastEnd.toFixed(2)}s (duration ${clipDuration.toFixed(2)}s).`,
      );""",
"""      await timelineUI.addClipToTrack(project, trackId, mediaItem.id, lastEnd, clipDuration);

      playback?.setProject(project);
      scheduleAutosave();
      log(
        `Added "${file.name}" to "${targetTrack.name}" at ${lastEnd.toFixed(2)}s (duration ${clipDuration.toFixed(2)}s).`,
      );""",
"importClipToTrack autosave hook",
)

apply(
"""  try {
    getVideoEngine().clearCache();
    titleEngine.clear();
    refreshTextClips();
    log("Cleared previous clip's frame cache before importing.");
  } catch {
    // VideoEngine not initialized yet on the very first import — fine, nothing to clear.
  }

  setStatus("Importing media…", "working");""",
"""  try {
    getVideoEngine().clearCache();
    titleEngine.clear();
    refreshTextClips();
    log("Cleared previous clip's frame cache before importing.");
  } catch {
    // VideoEngine not initialized yet on the very first import — fine, nothing to clear.
  }

  if (project) {
    void storageEngine.deleteProject(project.id).catch(() => {});
  }
  dismissRestoreBanner();

  setStatus("Importing media…", "working");""",
"fileInput cleanup of previous autosave",
)

apply(
"""    seekBar.max = String(sourceDuration);
    seekBar.disabled = false;
    playBtn.disabled = false;
    exportBtn.disabled = false;
    refreshTextClips();

    await playback!.seek(0);
    setStatus("Ready", "done");
    log("Timeline built: 1 track, 1 clip. Ready to play, trim, and export.");""",
"""    seekBar.max = String(sourceDuration);
    seekBar.disabled = false;
    playBtn.disabled = false;
    exportBtn.disabled = false;
    refreshTextClips();

    await playback!.seek(0);
    setStatus("Ready", "done");
    log("Timeline built: 1 track, 1 clip. Ready to play, trim, and export.");
    void persistProjectNow();""",
"fresh import immediate save",
)

apply(
"""log("OpenReel MVP loaded. Pick a video file to begin.");""",
"""log("OpenReel MVP loaded. Pick a video file to begin.");
void checkForAutosavedProject();""",
"startup restore check",
)

apply(
"""resetBtn.addEventListener("click", () => {
  cancelAnimationFrame(rafHandle);
  if (playback) {""",
"""resetBtn.addEventListener("click", () => {
  cancelAnimationFrame(rafHandle);
  if (autosaveTimer) {
    clearTimeout(autosaveTimer);
    autosaveTimer = null;
  }
  if (project) {
    void storageEngine.deleteProject(project.id).catch(() => {});
  }
  dismissRestoreBanner();
  if (playback) {""",
"resetBtn autosave cleanup",
)

with open(path, "w", encoding="utf-8") as f:
    f.write(src)
print(f"Patched {path}: autosave, session-restore banner, and cleanup wired in.")
PYEOF

echo ""
echo "Verifying TypeScript compiles..."
npx tsc --noEmit -p tsconfig.json
echo "tsc: clean."
python3 - src/main.ts <<'PYEOF'
import sys
path = "src/main.ts"
with open(path, encoding="utf-8") as f:
    src = f.read()

old = """import {
  getMediaImportService,
  createTrack,
  createClip,
  calculateProjectDuration,
  createStorageEngine,
  createProjectSerializer,
  type Project,
  type Track,
  type Clip,
} from "@openreel/core";"""
new = """import {
  getMediaImportService,
  createTrack,
  createClip,
  calculateProjectDuration,
  createStorageEngine,
  createProjectSerializer,
  type Project,
  type Track,
  type Clip,
} from "@openreel/core";

function findChangedMediaIds(oldProject: Project | null, newProject: Project): Set<string> {
  type ClipSignature = { mediaId: string; trackId: string; startTime: number; inPoint: number; outPoint: number };
  const oldClips = new Map<string, ClipSignature>();
  if (oldProject) {
    for (const t of oldProject.timeline.tracks) {
      for (const c of t.clips) {
        oldClips.set(c.id, { mediaId: c.mediaId, trackId: t.id, startTime: c.startTime, inPoint: c.inPoint, outPoint: c.outPoint });
      }
    }
  }

  const changed = new Set<string>();
  const newClipIds = new Set<string>();
  for (const t of newProject.timeline.tracks) {
    for (const c of t.clips) {
      newClipIds.add(c.id);
      const prev = oldClips.get(c.id);
      if (!prev) {
        changed.add(c.mediaId);
        continue;
      }
      if (
        prev.trackId !== t.id ||
        prev.startTime !== c.startTime ||
        prev.inPoint !== c.inPoint ||
        prev.outPoint !== c.outPoint
      ) {
        changed.add(c.mediaId);
      }
    }
  }
  for (const [id, prev] of oldClips) {
    if (!newClipIds.has(id)) {
      changed.add(prev.mediaId);
    }
  }
  return changed;
}"""
if src.count(old) != 1:
    sys.exit(f"ERROR: import-block anchor found {src.count(old)} time(s), expected 1")
src = src.replace(old, new, 1)

old2 = """    onProjectChanged: (updatedProject) => {
      project = updatedProject;
      playback?.updateProjectPreservingPlaybackState(updatedProject);
      // A trim/split/move/ripple-delete can change the overall project
      // duration — keep the preview seek bar and time label in step with
      // it rather than the stale duration captured at import time.
      sourceDuration = updatedProject.timeline.duration;
      seekBar.max = String(sourceDuration);
      // The video engine's frame cache is keyed independently of the
      // timeline's clip data — an edit (trim/split/move) doesn't tell it
      // anything changed, so it can keep serving stale pre-edit frames
      // until they age out naturally. Clear it on every edit, same as
      // what already happens on a fresh import, so playback reflects the
      // edit immediately instead of needing a few play/pause cycles.
      try {
        getVideoEngine().clearCache();
      } catch {
        // Not initialized yet — nothing to clear.
      }
      scheduleAutosave();
    },"""
new2 = """    onProjectChanged: (updatedProject) => {
      const changedMediaIds = findChangedMediaIds(project, updatedProject);
      project = updatedProject;
      playback?.updateProjectPreservingPlaybackState(updatedProject);
      sourceDuration = updatedProject.timeline.duration;
      seekBar.max = String(sourceDuration);
      try {
        const engine = getVideoEngine();
        if (changedMediaIds.size > 0) {
          for (const id of changedMediaIds) engine.invalidateMedia(id);
        } else {
          engine.clearCache();
        }
      } catch {
        // Not initialized yet — nothing to clear.
      }
      scheduleAutosave();
    },"""
if src.count(old2) != 1:
    sys.exit(f"ERROR: onProjectChanged anchor found {src.count(old2)} time(s), expected 1")
src = src.replace(old2, new2, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(src)
print(f"Patched {path}: edits now invalidate only the media they actually touched, not the whole frame cache.")
PYEOF

echo ""
echo "Verifying TypeScript compiles..."
npx tsc --noEmit -p tsconfig.json
echo "tsc: clean."
python3 - src/index.html <<'PYEOF'
import sys
path = "src/index.html"
with open(path, encoding="utf-8") as f:
    src = f.read()

old = """    </section>

    <div class="area-panels">"""
new = """    </section>

    <div class="panel-resizer" id="panelResizer" title="Drag to resize \u2014 double-click to reset"></div>

    <div class="area-panels">"""
if src.count(old) != 1:
    sys.exit(f"ERROR: preview/panels boundary anchor found {src.count(old)} time(s), expected 1")
src = src.replace(old, new, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(src)
print(f"Patched {path}: added drag handle between preview and panels.")
PYEOF

python3 - src/theme-default.css <<'PYEOF'
import sys
path = "src/theme-default.css"
with open(path, encoding="utf-8") as f:
    src = f.read()

old_doc = """  The whole app layout is one CSS Grid (.app-layout) with NAMED AREAS:
  header, preview, panels, actions, log. The HTML doesn't hardcode any
  particular arrangement — a custom theme can move, resize, hide, or
  reorder any area purely by redeclaring grid-template-areas /
  grid-template-columns, with zero HTML or JS changes."""
new_doc = """  The whole app layout is one CSS Grid (.app-layout) with NAMED AREAS:
  header, preview, resize, panels, actions, log. The HTML doesn't hardcode
  any particular arrangement — a custom theme can move, resize, hide, or
  reorder any area purely by redeclaring grid-template-areas /
  grid-template-columns, with zero HTML or JS changes. "resize" is the
  draggable divider between preview and panels — main.ts writes an inline
  grid-template-columns override onto .app-layout while dragging it or
  restoring a saved width, which will beat this file's own column rule
  while active; set the columns back to "" (or reload) to see this file's
  values again."""
if src.count(old_doc) != 1:
    sys.exit(f"ERROR: architecture doc-comment anchor found {src.count(old_doc)} time(s), expected 1")
src = src.replace(old_doc, new_doc, 1)

old1 = """.app-layout {
  display: grid;
  gap: 16px;
  width: 100%;
  grid-template-columns: minmax(480px, 1fr) minmax(280px, 360px);
  grid-template-areas:
    "header   header"
    "preview  panels"
    "actions  actions"
    "timeline timeline"
    "log      log";
}

.area-header   { grid-area: header; }
.area-preview  { grid-area: preview; }
.area-panels   { grid-area: panels; display: flex; flex-direction: column; gap: 12px; }
.area-actions  { grid-area: actions; }
.area-timeline { grid-area: timeline; }
.area-log      { grid-area: log; }"""
new1 = """.app-layout {
  display: grid;
  gap: 16px;
  width: 100%;
  grid-template-columns: minmax(480px, 1fr) 6px minmax(240px, 480px);
  grid-template-areas:
    "header   header  header"
    "preview  resize  panels"
    "actions  actions actions"
    "timeline timeline timeline"
    "log      log     log";
}

.area-header   { grid-area: header; }
.area-preview  { grid-area: preview; min-width: 0; }
.panel-resizer {
  grid-area: resize;
  cursor: col-resize;
  background: var(--border);
  border-radius: 3px;
  touch-action: none;
}
.panel-resizer:hover,
.panel-resizer:active {
  background: var(--accent, #4fa3d1);
}
.area-panels   { grid-area: panels; display: flex; flex-direction: column; gap: 12px; min-width: 0; }
.area-actions  { grid-area: actions; }
.area-timeline { grid-area: timeline; }
.area-log      { grid-area: log; }"""
if src.count(old1) != 1:
    sys.exit(f"ERROR: .app-layout anchor found {src.count(old1)} time(s), expected 1")
src = src.replace(old1, new1, 1)

old2 = """  .app-layout {
    grid-template-columns: 1fr;
    grid-template-areas:
      "header"
      "preview"
      "panels"
      "actions"
      "timeline"
      "log";
  }"""
new2 = """  .app-layout {
    grid-template-columns: 1fr !important;
    grid-template-areas:
      "header"
      "preview"
      "panels"
      "actions"
      "timeline"
      "log";
  }

  .panel-resizer {
    display: none;
  }"""
if src.count(old2) != 1:
    sys.exit(f"ERROR: mobile breakpoint anchor found {src.count(old2)} time(s), expected 1")
src = src.replace(old2, new2, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(src)
print(f"Patched {path}: real drag-resize divider between preview and panels, mobile-safe.")
PYEOF

python3 - src/main.ts <<'PYEOF'
import sys
path = "src/main.ts"
with open(path, encoding="utf-8") as f:
    src = f.read()

old = """log("OpenReel MVP loaded. Pick a video file to begin.");
void checkForAutosavedProject();"""
new = """const appLayoutEl = document.querySelector<HTMLElement>(".app-layout");
const panelResizer = document.getElementById("panelResizer");
const PREVIEW_WIDTH_KEY = "openreel:previewColWidthPx";
const DESKTOP_BREAKPOINT = "(min-width: 901px)";

function applyPreviewWidth(px: number): void {
  if (!appLayoutEl) return;
  appLayoutEl.style.gridTemplateColumns = `${px}px 6px minmax(240px, 480px)`;
}

function clearPreviewWidthOverride(): void {
  if (!appLayoutEl) return;
  appLayoutEl.style.gridTemplateColumns = "";
}

function syncPreviewWidthForViewport(): void {
  if (!window.matchMedia(DESKTOP_BREAKPOINT).matches) {
    clearPreviewWidthOverride();
    return;
  }
  const saved = localStorage.getItem(PREVIEW_WIDTH_KEY);
  if (saved) applyPreviewWidth(Number(saved));
}

syncPreviewWidthForViewport();
window.addEventListener("resize", syncPreviewWidthForViewport);

if (panelResizer && appLayoutEl) {
  let dragging = false;

  panelResizer.addEventListener("pointerdown", (e) => {
    if (!window.matchMedia(DESKTOP_BREAKPOINT).matches) return;
    dragging = true;
    panelResizer.setPointerCapture((e as PointerEvent).pointerId);
  });

  panelResizer.addEventListener("pointermove", (e) => {
    if (!dragging) return;
    const rect = appLayoutEl.getBoundingClientRect();
    const minPreview = 480;
    const maxPreview = Math.max(minPreview, rect.width - 240 - 6 - 32);
    const newWidth = Math.min(maxPreview, Math.max(minPreview, (e as PointerEvent).clientX - rect.left));
    applyPreviewWidth(newWidth);
  });

  const endDrag = (e: Event) => {
    if (!dragging) return;
    dragging = false;
    const widthPx = parseFloat(getComputedStyle(appLayoutEl).gridTemplateColumns.split(" ")[0]);
    if (!Number.isNaN(widthPx)) {
      localStorage.setItem(PREVIEW_WIDTH_KEY, String(widthPx));
    }
    panelResizer.releasePointerCapture((e as PointerEvent).pointerId);
  };
  panelResizer.addEventListener("pointerup", endDrag);
  panelResizer.addEventListener("pointercancel", endDrag);

  panelResizer.addEventListener("dblclick", () => {
    localStorage.removeItem(PREVIEW_WIDTH_KEY);
    clearPreviewWidthOverride();
  });
}

log("OpenReel MVP loaded. Pick a video file to begin.");
void checkForAutosavedProject();"""
if src.count(old) != 1:
    sys.exit(f"ERROR: startup anchor found {src.count(old)} time(s), expected 1")
src = src.replace(old, new, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(src)
print(f"Patched {path}: wired up real drag-to-resize for the preview/panels divider.")
PYEOF

python3 - src/core-lib/src/playback/master-timeline-clock.ts <<'PYEOF'
import sys
path = "src/core-lib/src/playback/master-timeline-clock.ts"
with open(path, encoding="utf-8") as f:
    src = f.read()

old = """  seek(time: number): void {
    const clampedTime = Math.max(0, Math.min(time, this.duration || Infinity));

    if (this.state === "playing") {"""
new = """  seek(time: number): void {
    const clampedTime = Math.max(0, Math.min(time, this.duration || Infinity));

    if (Math.abs(clampedTime - this.currentTime) > 2) {
      console.warn(
        `[clock] large seek: ${this.currentTime.toFixed(2)}s -> ${clampedTime.toFixed(2)}s (requested ${time.toFixed(2)}s, state=${this.state})`,
        new Error("seek call site").stack,
      );
    }

    if (this.state === "playing") {"""
if src.count(old) != 1:
    sys.exit(f"ERROR: seek() anchor found {src.count(old)} time(s), expected 1")
src = src.replace(old, new, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(src)
print(f"Patched {path}: added stack-trace diagnostic for unexplained large seeks.")
PYEOF

echo ""
echo "Verifying TypeScript compiles..."
npx tsc --noEmit -p tsconfig.json
echo "tsc: clean."
python3 - src/core-lib/src/video/video-engine.ts <<'PYEOF'
import sys
path = "src/core-lib/src/video/video-engine.ts"
with open(path, encoding="utf-8") as f:
    src = f.read()

def apply(old, new, label):
    global src
    n = src.count(old)
    if n != 1:
        sys.exit(f"ERROR: anchor for '{label}' found {n} time(s), expected 1")
    src = src.replace(old, new, 1)

apply(
"""              const scaledTransform: Transform = {
                ...transform,
                position: {
                  x: transform.position.x * scaleX,
                  y: transform.position.y * scaleY,
                },
                scale: {
                  x: transform.scale.x * scaleX,
                  y: transform.scale.y * scaleY,
                },
              };""",
"""              const scaledTransform: Transform = {
                ...transform,
                position: {
                  x: transform.position.x * scaleX,
                  y: transform.position.y * scaleY,
                },
              };""",
"compound-clip scaledTransform",
)

apply(
"""            const scaledTransform: Transform = {
              ...finalTransform,
              position: {
                x: finalTransform.position.x * scaleX,
                y: finalTransform.position.y * scaleY,
              },
              scale: {
                x: finalTransform.scale.x * scaleX,
                y: finalTransform.scale.y * scaleY,
              },
            };""",
"""            const scaledTransform: Transform = {
              ...finalTransform,
              position: {
                x: finalTransform.position.x * scaleX,
                y: finalTransform.position.y * scaleY,
              },
            };""",
"main-clip scaledTransform",
)

with open(path, "w", encoding="utf-8") as f:
    f.write(src)
print(f"Patched {path}: removed the redundant resolution-ratio scale that was double-shrinking every clip whenever the render target differs from native resolution.")
PYEOF

echo ""
echo "Verifying TypeScript compiles..."
npx tsc --noEmit -p tsconfig.json
echo "tsc: clean."
