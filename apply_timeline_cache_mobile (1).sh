mkdir -p src
cat > src/main.ts <<'OPENREEL_APPLY_EOF'
import {
  getMediaImportService,
  createTrack,
  createClip,
  type Project,
  type Track,
  type Clip,
} from "@openreel/core";
import { getVideoEngine } from "@openreel/core/video/video-engine";
import { getAudioEngine } from "@openreel/core/audio/audio-engine";
import { PlaybackController } from "@openreel/core/playback/playback-controller";
import { getExportEngine } from "@openreel/core/export/export-engine";
import { DEFAULT_VIDEO_SETTINGS } from "@openreel/core/export/types";
import { titleEngine } from "@openreel/core/text/title-engine";
import { DEFAULT_TEXT_STYLE } from "@openreel/core/text/types";
import { TimelineUI } from "./timeline-ui";
// ?url gives a build-safe, fingerprint-stable URL string rather than
// inlining the CSS — Vite's HTML <link> processing strips custom
// attributes like id from stylesheet tags it fingerprints, which breaks
// getElementById-based theme swapping. Creating the link element ourselves
// avoids that entirely.
import defaultThemeUrl from "./theme-default.css?url";

const themeLink = document.createElement("link");
themeLink.id = "theme-link";
themeLink.rel = "stylesheet";
themeLink.href = defaultThemeUrl;
document.head.appendChild(themeLink);

const log = (msg: string) => {
  const el = document.getElementById("log")!;
  el.textContent += msg + "\n";
  el.scrollTop = el.scrollHeight;
  console.log(msg);
};

// The engine catches its own frame-render errors internally and sends them to
// console.error rather than surfacing them through any public API — mirror
// console.error into our own log panel so those aren't invisible without DevTools.
const originalConsoleError = console.error.bind(console);
console.error = (...args: unknown[]) => {
  originalConsoleError(...args);
  log("[console.error] " + args.map((a) => (a instanceof Error ? a.message : String(a))).join(" "));
};

const setStatus = (text: string, cls: "idle" | "working" | "done" | "error") => {
  const el = document.getElementById("status")!;
  el.textContent = text;
  el.className = cls;
};

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

const fileInput = $<HTMLInputElement>("fileInput");
const canvas = $<HTMLCanvasElement>("canvas");
const playBtn = $<HTMLButtonElement>("playBtn");
const seekBar = $<HTMLInputElement>("seekBar");
const timeLabel = $<HTMLSpanElement>("timeLabel");
const exportBtn = $<HTMLButtonElement>("exportBtn");
const themeUrlInput = $<HTMLInputElement>("themeUrlInput");
const loadThemeBtn = $<HTMLButtonElement>("loadThemeBtn");
const resetThemeBtn = $<HTMLButtonElement>("resetThemeBtn");

let textTrack: Track | null = null;

let project: Project | null = null;
let track: Track | null = null;
let clip: Clip | null = null;
let mediaId: string | null = null;
let sourceDuration = 0;
let playback: PlaybackController | null = null;
let rafHandle = 0;

const timelineRulerEl = $<HTMLDivElement>("timelineRuler");
const timelineTracksEl = $<HTMLDivElement>("timelineTracks");
const timelineTimecodeEl = $<HTMLSpanElement>("timelineTimecode");
const timelineContextEl = $<HTMLDivElement>("timelineContext");
const addVideoTrackBtn = $<HTMLButtonElement>("addVideoTrackBtn");
const addAudioTrackBtn = $<HTMLButtonElement>("addAudioTrackBtn");
const addTextTrackBtn = $<HTMLButtonElement>("addTextTrackBtn");

// Every title (TextClip) mutation goes through titleEngine, not the
// project's own timeline.tracks array — refresh the timeline's copy of
// them after any add/update/delete so the UI stays in sync.
function refreshTextClips() {
  timelineUI.setTextClips(titleEngine.getAllTextClips());
}

async function resumePlayback() {
  if (!playback) return;
  if (playback.isPlaying()) return;
  await playback.play();
  playBtn.textContent = "Pause";
  const statsInterval = setInterval(() => {
    if (!playback || !playback.isPlaying()) {
      clearInterval(statsInterval);
      return;
    }
    log(`stats: ${JSON.stringify(playback.getStats())}`);
  }, 2000);
}

function pausePlayback() {
  if (!playback || !playback.isPlaying()) return;
  playback.pause();
  playBtn.textContent = "Play";
}

const timelineUI = new TimelineUI(
  {
    ruler: timelineRulerEl,
    tracks: timelineTracksEl,
    timecode: timelineTimecodeEl,
    context: timelineContextEl,
    zoomSlider: $("timelineZoomSlider"),
    zoomInBtn: $("timelineZoomInBtn"),
    zoomOutBtn: $("timelineZoomOutBtn"),
    undoBtn: $("timelineUndoBtn"),
    redoBtn: $("timelineRedoBtn"),
  },
  {
    onSeek: (t) => {
      playback?.seek(t);
    },
    onPlay: () => void resumePlayback(),
    onPause: () => pausePlayback(),
    onProjectChanged: (updatedProject) => {
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
    },
    onAddClipToTrack: (trackId) => importClipToTrack(trackId),
    onLog: (message) => log(message),
    onAddTitle: ({ trackId, text, fontSize, color, start, duration }) => {
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
    },
    onActionError: (message) => log(`Timeline action failed: ${message}`),
  },
);

addVideoTrackBtn.addEventListener("click", () => timelineUI.addTrack("video"));
addAudioTrackBtn.addEventListener("click", () => timelineUI.addTrack("audio"));
addTextTrackBtn.addEventListener("click", () => timelineUI.addTrack("text"));

// Adds a clip onto an EXISTING track without touching the rest of the
// project — separate from fileInput's handler above, which always starts
// a brand-new project from scratch. Opens its own one-off file picker
// scoped to whichever track's "+ clip" button was clicked, appends the
// new clip right after whatever's already on that track.
async function importClipToTrack(trackId: string) {
  if (!project) return;
  const targetTrack = project.timeline.tracks.find((t) => t.id === trackId);
  if (!targetTrack) return;

  const input = document.createElement("input");
  input.type = "file";
  input.accept =
    targetTrack.type === "audio" ? "audio/*" : targetTrack.type === "image" ? "image/*" : "video/*";
  input.style.display = "none";
  document.body.appendChild(input);

  input.addEventListener("change", async () => {
    const file = input.files?.[0];
    document.body.removeChild(input);
    if (!file || !project) return;

    log(`Importing ${file.name} onto track "${targetTrack.name}"…`);
    try {
      const importService = getMediaImportService();
      await importService.initialize();
      const result = await importService.importMedia(file, {
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
    } catch (e) {
      log(`Error importing clip: ${e instanceof Error ? e.message : String(e)}`);
    }
  });

  input.click();
}

async function setupPlayback() {
  const videoEngine = getVideoEngine();
  const audioEngine = getAudioEngine();
  await videoEngine.initialize();
  await audioEngine.initialize();
  playback = new PlaybackController();
  await playback.initialize(videoEngine, audioEngine);
  playback.setDisplayCanvas(canvas);
  log("VideoEngine + AudioEngine initialized, PlaybackController wired up.");
}

function tickTimeDisplay() {
  if (playback && project) {
    const t = playback.getCurrentTime();
    seekBar.value = String(t);
    timeLabel.textContent = `${t.toFixed(2)}s / ${sourceDuration.toFixed(2)}s`;
    timelineUI.setCurrentTime(t);
  }
  rafHandle = requestAnimationFrame(tickTimeDisplay);
}

fileInput.addEventListener("change", async () => {
  const file = fileInput.files?.[0];
  if (!file) return;

  // Free the previous clip's decoded frames / caches before loading a new
  // one. On modest hardware, importing a second clip without releasing the
  // first one's memory is exactly what causes flaky mid-pipeline errors and
  // page freezes — nothing in the engine does this automatically between
  // separate imports in the same session.
  if (playback) {
    if (playback.isPlaying()) playback.pause();
    playBtn.textContent = "Play";
  }
  try {
    getVideoEngine().clearCache();
    titleEngine.clear();
    refreshTextClips();
    log("Cleared previous clip's frame cache before importing.");
  } catch {
    // VideoEngine not initialized yet on the very first import — fine, nothing to clear.
  }

  setStatus("Importing media…", "working");
  log(`Importing ${file.name} (${(file.size / 1_000_000).toFixed(1)} MB)…`);

  try {
    const importService = getMediaImportService();
    await importService.initialize();
    // Thumbnails and a full waveform analysis both run by default on every
    // import (5 thumbnail frames + 100 waveform samples/sec across the
    // ENTIRE file duration) — real, substantial decode work this MVP's UI
    // doesn't even display anywhere yet. Skipping both cuts import time
    // significantly, especially on longer files.
    const importStart = performance.now();
    const result = await importService.importMedia(file, {
      generateThumbnails: false,
      generateWaveform: false,
    });
    const importMs = performance.now() - importStart;

    if (!result.success || !result.media) {
      setStatus("Import failed", "error");
      log(`Import failed: ${result.error ?? "unknown error"}`);
      return;
    }

    const mediaItem = importService.processedMediaToMediaItem(result.media);
    sourceDuration = result.media.metadata.duration;
    log(
      `Imported: ${result.media.metadata.width}x${result.media.metadata.height} @ ${result.media.metadata.frameRate}fps, ` +
        `${sourceDuration.toFixed(2)}s, codec=${result.media.metadata.codec} (import took ${importMs.toFixed(0)}ms)`,
    );

    mediaId = mediaItem.id;
    track = createTrack("video", "V1");
    clip = createClip(mediaId, track.id, 0, sourceDuration);
    track = { ...track, clips: [clip] };

    // createTrack()'s type parameter doesn't include "text" (it's a video-
    // editing-only helper), but Track.type itself supports it — build the
    // text track directly. Text clips themselves aren't stored in this
    // track's `clips` array at all; they live in the titleEngine singleton
    // and just reference this track's id, which VideoEngine looks up during
    // compositing.
    textTrack = {
      id: `track-${Date.now()}-text`,
      type: "text",
      name: "Titles",
      clips: [],
      transitions: [],
      locked: false,
      hidden: false,
      muted: false,
      solo: false,
    };

    project = {
      id: `project-${Date.now()}`,
      name: file.name,
      createdAt: Date.now(),
      modifiedAt: Date.now(),
      settings: {
        width: result.media.metadata.width,
        height: result.media.metadata.height,
        frameRate: result.media.metadata.frameRate || 30,
        sampleRate: result.media.metadata.sampleRate || 48000,
        channels: result.media.metadata.channels || 2,
      },
      mediaLibrary: { items: [mediaItem] },
      timeline: {
        tracks: [track, textTrack],
        subtitles: [],
        duration: sourceDuration,
        markers: [],
      },
    };

    if (!playback) await setupPlayback();
    playback!.setProject(project);
    timelineUI.setProject(project);
    titleEngine.initialize(project.settings.width, project.settings.height);
    canvas.width = project.settings.width;
    canvas.height = project.settings.height;
    playback!.setDisplayCanvas(canvas); // re-bind now that dimensions are final

    let loggedFirstFrame = false;
    playback!.addEventListener("framerendered", (event: any) => {
      if (!loggedFirstFrame) {
        loggedFirstFrame = true;
        log(`First frame rendered at t=${event.time?.toFixed?.(2)}s (check: is the canvas visibly updating?)`);
      }
    });

    seekBar.max = String(sourceDuration);
    seekBar.disabled = false;
    playBtn.disabled = false;
    exportBtn.disabled = false;
    refreshTextClips();

    await playback!.seek(0);
    setStatus("Ready", "done");
    log("Timeline built: 1 track, 1 clip. Ready to play, trim, and export.");

    cancelAnimationFrame(rafHandle);
    tickTimeDisplay();
  } catch (e) {
    setStatus("Error", "error");
    log(`Error during import: ${e instanceof Error ? e.message : String(e)}`);
  }
});

playBtn.addEventListener("click", () => {
  if (!playback) return;
  if (playback.isPlaying()) pausePlayback();
  else void resumePlayback();
});

seekBar.addEventListener("input", async () => {
  if (!playback) return;
  await playback.seek(parseFloat(seekBar.value));
});

// Trimming and adding titles both now happen directly in the timeline
// panel (drag the clip handles, or use the selected-clip / "+ Title"
// controls in the timeline's contextual row) — see timeline-ui.ts.

// Theming: swap the stylesheet by URL only, never by pasting CSS in — same
// approach as Jellyfin's custom-CSS setting. Persist the chosen URL so it
// survives a page reload.
const THEME_STORAGE_KEY = "openreel-theme-url";

const savedThemeUrl = localStorage.getItem(THEME_STORAGE_KEY);
if (savedThemeUrl) {
  themeLink.href = savedThemeUrl;
  themeUrlInput.value = savedThemeUrl;
  log(`Loaded saved theme: ${savedThemeUrl}`);
}

loadThemeBtn.addEventListener("click", () => {
  const url = themeUrlInput.value.trim();
  if (!url) {
    log("Enter a theme CSS URL first.");
    return;
  }
  themeLink.href = url;
  localStorage.setItem(THEME_STORAGE_KEY, url);
  log(`Theme loaded from: ${url}`);
});

resetThemeBtn.addEventListener("click", () => {
  themeLink.href = defaultThemeUrl;
  themeUrlInput.value = "";
  localStorage.removeItem(THEME_STORAGE_KEY);
  log("Theme reset to default.");
});

// Fallback writable stream for browsers/contexts without showSaveFilePicker —
// buffers to memory and triggers a download on close. Implements the same
// truncate/seek surface our hardware-encode-retry patch relies on.
function createInMemoryWritable(filename: string): FileSystemWritableFileStream {
  let chunks: Uint8Array[] = [];
  let position = 0;

  const stream = {
    async write(data: FileSystemWriteChunkType) {
      let bytes: Uint8Array;
      if (data instanceof Blob) bytes = new Uint8Array(await data.arrayBuffer());
      else if (data instanceof ArrayBuffer) bytes = new Uint8Array(data);
      else if (ArrayBuffer.isView(data)) bytes = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
      else if (typeof data === "object" && data !== null && "type" in data && (data as any).type === "write") {
        const chunkData = (data as any).data;
        bytes = chunkData instanceof Blob ? new Uint8Array(await chunkData.arrayBuffer()) : new Uint8Array(chunkData);
      } else {
        bytes = new Uint8Array(0);
      }
      chunks.push(bytes);
      position += bytes.byteLength;
    },
    async seek(offset: number) {
      position = offset;
    },
    async truncate(size: number) {
      if (size === 0) {
        chunks = [];
        position = 0;
      }
    },
    async close() {
      const blob = new Blob(chunks as BlobPart[], { type: "video/mp4" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = filename;
      a.click();
      URL.revokeObjectURL(url);
    },
    async abort() {
      chunks = [];
    },
  };
  return stream as unknown as FileSystemWritableFileStream;
}

exportBtn.addEventListener("click", async () => {
  if (!project) return;
  exportBtn.disabled = true;
  resetBtn.disabled = true;
  setStatus("Exporting…", "working");
  log("Export started — this can take anywhere from several seconds to a couple minutes depending on length/resolution and whether hardware encoding needs to fall back to software. Progress logs below every ~10%.");

  try {
    const exportEngine = getExportEngine();
    await exportEngine.initialize();

    let writable: FileSystemWritableFileStream;
    const filename = `${project.name.replace(/\.[^/.]+$/, "")}-export.mp4`;

    if ("showSaveFilePicker" in window) {
      try {
        const handle = await (window as any).showSaveFilePicker({
          suggestedName: filename,
          types: [{ description: "MP4 video", accept: { "video/mp4": [".mp4"] } }],
        });
        writable = await handle.createWritable();
        log("Using native File System Access API for export output.");
      } catch (e) {
        log("Save picker cancelled or unavailable, falling back to in-memory buffer + download.");
        writable = createInMemoryWritable(filename);
      }
    } else {
      writable = createInMemoryWritable(filename);
    }

    const generator = exportEngine.exportVideo(
      project,
      { ...DEFAULT_VIDEO_SETTINGS, width: project.settings.width, height: project.settings.height, frameRate: project.settings.frameRate },
      writable,
    );

    let result;
    let lastLoggedPercent = -1;
    while (true) {
      const step = await generator.next();
      if (step.done) {
        result = step.value;
        break;
      }
      const p = step.value;
      const percent = Math.round((p.currentFrame / Math.max(p.totalFrames, 1)) * 100);
      setStatus(`Exporting… ${percent}%`, "working");
      // The status text above is easy to miss (small, no dedicated area) —
      // also print milestones to the log panel, which is what people
      // actually watch/copy during a long export.
      if (percent >= lastLoggedPercent + 10) {
        lastLoggedPercent = percent;
        log(`Export progress: ${percent}% (frame ${p.currentFrame}/${p.totalFrames})`);
      }
    }

    if (result.success) {
      setStatus("Export complete", "done");
      log(`Export succeeded: ${filename}`);
    } else {
      setStatus("Export failed", "error");
      log(`Export failed: ${result.error?.message ?? "unknown error"} (phase: ${result.error?.phase ?? "?"})`);
    }
  } catch (e) {
    setStatus("Export failed", "error");
    log(`Export threw: ${e instanceof Error ? e.message : String(e)}`);
  } finally {
    exportBtn.disabled = false;
    resetBtn.disabled = false;
  }
});

log("OpenReel MVP loaded. Pick a video file to begin.");

const resetBtn = $<HTMLButtonElement>("resetBtn");
resetBtn.addEventListener("click", () => {
  cancelAnimationFrame(rafHandle);
  if (playback) {
    playback.pause();
    playback.dispose();
    playback = null;
  }
  try {
    getVideoEngine().dispose();
  } catch {
    // not initialized yet, nothing to dispose
  }
  titleEngine.clear();
  refreshTextClips();
  project = null;
  track = null;
  clip = null;
  textTrack = null;
  mediaId = null;
  sourceDuration = 0;
  timelineUI.setProject(null);

  const ctx = canvas.getContext("2d");
  ctx?.clearRect(0, 0, canvas.width, canvas.height);
  seekBar.value = "0";
  seekBar.disabled = true;
  playBtn.disabled = true;
  playBtn.textContent = "Play";
  exportBtn.disabled = true;
  fileInput.value = "";
  timeLabel.textContent = "0.00s / 0.00s";
  setStatus("Waiting for a video…", "idle");
  log("--- Reset: engines disposed, memory freed. Pick a new file to start fresh. ---");
});
OPENREEL_APPLY_EOF
cat > src/theme-default.css <<'OPENREEL_APPLY_EOF'
/*
  OpenReel MVP — default theme.
  Loosely modeled on Adobe Premiere Pro's dark panel UI: charcoal
  backgrounds, sharp/flat panels, a cyan-blue accent for active state and
  the playhead.

  ARCHITECTURE FOR CUSTOM THEMES
  -------------------------------
  The whole app layout is one CSS Grid (.app-layout) with NAMED AREAS:
  header, preview, panels, actions, log. The HTML doesn't hardcode any
  particular arrangement — a custom theme can move, resize, hide, or
  reorder any area purely by redeclaring grid-template-areas /
  grid-template-columns, with zero HTML or JS changes.

  A worked example: a touch/mobile theme just needs to stack everything
  in one column with bigger tap targets — see the @media block near the
  bottom of this file for exactly that, ready to copy into your own
  theme and adjust.

  To make your own theme: copy this file, change whatever you like, host
  it anywhere reachable by URL, and paste that URL into the "Theme URL"
  field in the app (or set localStorage key "openreel-theme-url"
  directly). You never need to paste CSS into the app itself — only a
  link to it, same idea as Jellyfin's custom-CSS setting.
*/

:root {
  --bg-app: #1e1e1e;
  --bg-panel: #262626;
  --bg-panel-raised: #2e2e2e;
  --bg-input: #1a1a1a;
  --border: #3a3a3a;
  --text-primary: #e8e8e8;
  --text-secondary: #999999;
  --text-dim: #6b6b6b;
  --accent: #4fc3f7;
  --accent-strong: #29b6f6;
  --accent-contrast: #0b1a1f;
  --danger: #ff6b6b;
  --success: #6dff9a;
  --warning: #ffd280;
  --font-ui: "Segoe UI", system-ui, -apple-system, sans-serif;
  --font-mono: "Consolas", "SFMono-Regular", Menlo, monospace;

  /* Referenced by .touch-target and form controls — bump this in a
     custom theme (e.g. to 48-56px) for a more touch-friendly feel
     without touching any other rule. */
  --tap-size: 40px;
}

* { box-sizing: border-box; }

body {
  background: var(--bg-app);
  color: var(--text-primary);
  font-family: var(--font-ui);
  margin: 0;
  padding: 20px;
  font-size: 13px;
}

/* ============ LAYOUT ============ */

.app-layout {
  display: grid;
  gap: 16px;
  max-width: 1400px;
  margin: 0 auto;
  grid-template-columns: minmax(320px, 480px) 1fr;
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
.area-log      { grid-area: log; }

h1 {
  font-size: 1.1rem;
  font-weight: 600;
  margin: 0 0 4px 0;
  letter-spacing: 0.02em;
}

.sub {
  color: var(--text-secondary);
  font-size: 0.8rem;
}

/* ============ PANELS ============ */

.panel {
  background: var(--bg-panel);
  border: 1px solid var(--border);
  border-radius: 2px;
  padding: 14px;
}

.panel-title {
  font-size: 0.72rem;
  color: var(--text-secondary);
  text-transform: uppercase;
  letter-spacing: 0.05em;
  margin: 0 0 10px 0;
  border-bottom: 1px solid var(--border);
  padding-bottom: 6px;
}

/* ============ CANVAS ============ */

#canvas {
  background: black;
  border: 1px solid var(--border);
  display: block;
  margin: 10px 0;
  width: 100%;
  height: auto;
}

/* ============ CONTROLS / FORM ELEMENTS ============ */

.controls {
  display: flex;
  gap: 10px;
  align-items: flex-end;
  flex-wrap: wrap;
}

.field { display: flex; flex-direction: column; gap: 4px; }
.field-grow { flex: 1 1 200px; }
.field-narrow input { width: 80px; }
.field-swatch input { width: 44px; padding: 2px; }

.field label {
  font-size: 0.72rem;
  color: var(--text-secondary);
  text-transform: uppercase;
  letter-spacing: 0.04em;
}

button {
  background: var(--bg-panel-raised);
  color: var(--text-primary);
  border: 1px solid var(--border);
  padding: 0 16px;
  min-height: var(--tap-size);
  border-radius: 2px;
  cursor: pointer;
  font-family: var(--font-ui);
  font-size: 0.85rem;
  transition: background-color 0.1s, border-color 0.1s;
}
button:hover:not(:disabled) {
  background: #3a3a3a;
  border-color: var(--accent);
}
button:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 1px;
}
button:active:not(:disabled) {
  background: #444;
}
button:disabled {
  color: var(--text-dim);
  cursor: default;
  opacity: 0.6;
}
button.primary {
  background: var(--accent-strong);
  color: var(--accent-contrast);
  border-color: var(--accent-strong);
  font-weight: 600;
}
button.primary:hover:not(:disabled) {
  background: var(--accent);
  border-color: var(--accent);
}

/* Explicit opt-in class for controls that should always meet a minimum
   touch target size (44x44 is the common accessibility baseline) even
   if the default theme's own button height is smaller. Redeclare
   --tap-size in a custom theme to resize every one of these at once. */
.touch-target {
  min-width: var(--tap-size);
  min-height: var(--tap-size);
}

input[type=range] {
  flex: 1 1 200px;
  min-width: 120px;
  accent-color: var(--accent);
  /* Native range inputs have a tiny hit area by default — pad the
     clickable/tappable height without changing the visual track size. */
  height: var(--tap-size);
  cursor: pointer;
}

input[type=text],
input[type=number],
select {
  background: var(--bg-input);
  border: 1px solid var(--border);
  color: var(--text-primary);
  padding: 0 10px;
  min-height: var(--tap-size);
  border-radius: 2px;
  font-family: var(--font-ui);
  font-size: 0.85rem;
  width: 100%;
}
input[type=text]:focus,
input[type=number]:focus,
select:focus {
  outline: none;
  border-color: var(--accent);
}
input[type=file] {
  color: var(--text-secondary);
  font-size: 0.85rem;
}
input[type=color] {
  border: 1px solid var(--border);
  border-radius: 2px;
  min-height: var(--tap-size);
  cursor: pointer;
}

/* ============ LOG / STATUS ============ */

#log {
  font-family: var(--font-mono);
  font-size: 0.75rem;
  color: var(--text-secondary);
  white-space: pre-wrap;
  max-height: 220px;
  overflow-y: auto;
  border-top: 1px solid var(--border);
  padding-top: 10px;
}

#status {
  font-size: 0.8rem;
  padding: 5px 10px;
  border-radius: 2px;
  display: inline-block;
  font-weight: 500;
}
.idle { background: var(--bg-panel-raised); color: var(--text-secondary); }
.working { background: #3a2c0d; color: var(--warning); }
.done { background: #0e2f16; color: var(--success); }
.error { background: #3a0d0d; color: var(--danger); }

/* ============ MULTITRACK TIMELINE ============
   Self-contained: every visual value here reads from the same --bg-...
   --border/--accent/--text-... variables as the rest of the theme, so a
   custom theme restyles the timeline for free just by overriding those
   variables — no timeline-specific overrides needed unless you want them. */

:root {
  /* Extra vars for the timeline only — still theme-overridable, but kept
     separate from the core palette above since a custom theme may want
     a different accent for text clips without touching --accent itself. */
  --text-clip-accent: #c792ea;
  --track-alt-tint: rgba(255, 255, 255, 0.025);
}

.timeline {
  background: var(--bg-panel);
  border: 1px solid var(--border);
  border-radius: 2px;
  padding: 10px;
  user-select: none;
}

.timeline-toolbar {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 8px;
  flex-wrap: wrap;
}

.timeline-toolbar-spacer {
  flex: 1 1 auto;
}

.timeline-toolbar .timecode {
  font-family: var(--font-mono);
  font-size: 0.78rem;
  color: var(--text-secondary);
  background: var(--bg-input);
  border: 1px solid var(--border);
  border-radius: 2px;
  padding: 4px 8px;
}

.timeline-zoom {
  display: flex;
  align-items: center;
  gap: 4px;
}

.timeline-zoom button {
  min-width: 28px;
  min-height: 28px;
  padding: 0;
  font-size: 0.95rem;
  line-height: 1;
}

.timeline-zoom input[type="range"] {
  width: 100px;
  min-width: 80px;
  flex: 0 0 auto;
  height: 28px;
}

#timelineUndoBtn,
#timelineRedoBtn {
  min-width: 32px;
  min-height: 32px;
  padding: 0;
  font-size: 1rem;
}

/* ---- Contextual row: selected-clip properties / add-title form ---- */

.timeline-context {
  display: none;
  border: 1px solid var(--border);
  border-radius: 2px;
  background: var(--bg-panel-raised);
  padding: 8px 10px;
  margin-bottom: 8px;
}

.timeline-context.visible {
  display: block;
}

.timeline-context-row {
  display: flex;
  align-items: flex-end;
  gap: 10px;
  flex-wrap: wrap;
}

.timeline-context-label {
  font-size: 0.78rem;
  font-weight: 600;
  color: var(--text-primary);
  padding-bottom: 8px;
  max-width: 220px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.timeline-scroll {
  overflow-x: auto;
  overflow-y: hidden;
  border: 1px solid var(--border);
  border-radius: 2px;
  background: var(--bg-input);
}

.timeline-ruler {
  position: relative;
  height: 24px;
  border-bottom: 1px solid var(--border);
  cursor: text;
  background: var(--bg-panel-raised);
}

.timeline-ruler-tick {
  position: absolute;
  top: 0;
  bottom: 0;
  border-left: 1px solid var(--border);
}

.timeline-ruler-tick-label {
  position: absolute;
  top: 3px;
  left: 4px;
  font-family: var(--font-mono);
  font-size: 0.65rem;
  color: var(--text-dim);
  white-space: nowrap;
}

.timeline-tracks {
  position: relative;
}

.timeline-track {
  display: flex;
  border-bottom: 1px solid var(--border);
}

.timeline-track:last-child {
  border-bottom: none;
}

.timeline-track.alt .timeline-track-lane {
  background: var(--track-alt-tint);
}

.timeline-track-header {
  position: sticky;
  left: 0;
  z-index: 2;
  width: 132px;
  flex: 0 0 132px;
  background: var(--bg-panel-raised);
  border-right: 1px solid var(--border);
  padding: 6px 8px;
  display: flex;
  flex-direction: column;
  justify-content: center;
  gap: 4px;
}

.timeline-track-name-row {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 6px;
}

.timeline-track-name {
  font-size: 0.74rem;
  font-weight: 600;
  color: var(--text-primary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.timeline-track-type {
  font-size: 0.6rem;
  color: var(--text-dim);
  text-transform: uppercase;
  letter-spacing: 0.04em;
  flex: 0 0 auto;
}

.timeline-track-actions {
  display: flex;
  align-items: center;
  gap: 4px;
}

.timeline-track-toggle {
  font-size: 0.72rem;
  line-height: 1;
  padding: 4px 6px;
  border: 1px solid var(--border);
  border-radius: 2px;
  background: var(--bg-input);
  color: var(--text-dim);
  cursor: pointer;
  min-height: 0;
  flex: 0 0 auto;
}

.timeline-track-toggle:hover:not(:disabled) {
  border-color: var(--accent);
  background: #3a3a3a;
}

.timeline-track-toggle.active {
  background: var(--accent);
  border-color: var(--accent-strong);
  color: var(--accent-contrast);
}

.timeline-track-add-clip {
  flex: 1 1 auto;
  min-width: 0;
  text-align: center;
  font-size: 0.68rem;
  padding: 4px 6px;
  border: 1px solid var(--accent);
  border-radius: 2px;
  background: var(--bg-input);
  color: var(--accent);
  cursor: pointer;
  min-height: 0;
  font-weight: 600;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.timeline-track-add-clip:hover {
  background: var(--accent);
  color: var(--accent-contrast);
}

.timeline-track-lane {
  position: relative;
  height: 60px;
  flex: 1 1 auto;
  cursor: text;
  transition: background-color 0.1s;
}

.timeline-clip {
  position: absolute;
  top: 4px;
  bottom: 4px;
  touch-action: none;
  border-radius: 3px;
  background: linear-gradient(180deg, color-mix(in srgb, var(--accent) 92%, white 8%), var(--accent-strong));
  border: 1px solid var(--accent-strong);
  color: var(--accent-contrast);
  font-size: 0.7rem;
  padding: 4px 7px;
  overflow: hidden;
  cursor: grab;
  box-sizing: border-box;
  box-shadow: 0 1px 2px rgba(0, 0, 0, 0.3);
  transition: filter 0.1s, box-shadow 0.1s;
}

.timeline-clip:hover {
  filter: brightness(1.08);
}

.timeline-clip-label {
  display: block;
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
  font-weight: 600;
  letter-spacing: 0.01em;
  pointer-events: none;
}

.timeline-clip.dragging {
  cursor: grabbing;
  opacity: 0.88;
  z-index: 3;
  box-shadow: 0 3px 8px rgba(0, 0, 0, 0.45);
}

.timeline-clip.selected {
  outline: 2px solid var(--text-primary);
  outline-offset: -1px;
  box-shadow: 0 0 0 3px color-mix(in srgb, var(--text-primary) 25%, transparent), 0 1px 2px rgba(0, 0, 0, 0.3);
}

.timeline-clip.locked {
  cursor: not-allowed;
  filter: saturate(0.4) brightness(0.8);
}

.timeline-clip[data-track-type="audio"] {
  background: linear-gradient(180deg, color-mix(in srgb, var(--success) 92%, white 8%), var(--success));
  border-color: var(--success);
  color: #06210f;
}

.timeline-clip[data-track-type="image"] {
  background: linear-gradient(180deg, color-mix(in srgb, var(--warning) 92%, white 8%), var(--warning));
  border-color: var(--warning);
  color: #2b1d00;
}

.timeline-clip-text,
.timeline-clip[data-track-type="text"] {
  background: linear-gradient(180deg, color-mix(in srgb, var(--text-clip-accent) 92%, white 8%), var(--text-clip-accent));
  border-color: var(--text-clip-accent);
  color: #1e0d29;
}

.timeline-clip-text .timeline-clip-label {
  font-style: italic;
}

.timeline-clip-handle {
  position: absolute;
  top: 0;
  bottom: 0;
  width: 7px;
  cursor: ew-resize;
  touch-action: none;
}

.timeline-clip-handle:hover {
  background: rgba(255, 255, 255, 0.25);
}

.timeline-clip-handle.left  { left: 0; border-radius: 3px 0 0 3px; }
.timeline-clip-handle.right { right: 0; border-radius: 0 3px 3px 0; }

.timeline-playhead {
  position: absolute;
  top: 0;
  bottom: 0;
  width: 1px;
  background: var(--danger);
  z-index: 4;
  pointer-events: none;
  box-shadow: 0 0 4px color-mix(in srgb, var(--danger) 60%, transparent);
}

.timeline-playhead::before {
  content: "";
  position: absolute;
  top: 0;
  left: -5px;
  border-left: 5px solid transparent;
  border-right: 5px solid transparent;
  border-top: 6px solid var(--danger);
}

/* ============ MOBILE / TOUCH EXAMPLE ============
   Worked example of what a touch-first custom theme would change.
   Copy this whole block (and the --tap-size bump above) as the starting
   point for your own mobile theme — nothing else in this file needs to
   change for the app to work, because layout lives entirely in
   .app-layout's grid-template-areas. */
@media (max-width: 720px) {
  :root {
    --tap-size: 48px; /* bigger fingers need bigger targets */
  }

  body {
    padding: 10px;
    font-size: 15px;
  }

  .app-layout {
    grid-template-columns: 1fr;
    grid-template-areas:
      "header"
      "preview"
      "panels"
      "actions"
      "timeline"
      "log";
  }

  .controls {
    align-items: stretch;
  }

  .controls > button,
  .controls > .field {
    flex: 1 1 100%;
  }

  input[type=range] {
    flex-basis: 100%;
  }

  .timeline-zoom input[type="range"] {
    width: 70px;
    min-width: 60px;
  }

  .timeline-context-row {
    align-items: stretch;
  }

  .timeline-context-row > .field,
  .timeline-context-row > button {
    flex: 1 1 100%;
  }

  /* The timeline's own small controls (trim handles, mute/lock, add-clip)
     are sized for a mouse pointer by default — a 7px handle or a 20px
     icon button is much too small to reliably grab with a finger. Bump
     them all up under the same breakpoint as the rest of the touch
     layout, and give the lane back some of the width the header was
     taking on a narrow phone screen. */
  .timeline-track-header {
    width: 96px;
    flex: 0 0 96px;
  }

  .timeline-track-name {
    font-size: 0.68rem;
  }

  .timeline-track-type {
    display: none;
  }

  .timeline-track-toggle,
  .timeline-track-add-clip {
    min-height: 32px;
    padding: 6px 5px;
  }

  .timeline-clip-handle {
    width: 16px;
  }

  .timeline-track-lane {
    height: 64px;
  }
}
OPENREEL_APPLY_EOF
echo "openreel-mvp: cache-invalidation-on-edit + mobile touch sizing applied."
