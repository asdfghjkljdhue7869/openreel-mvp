import {
  getMediaImportService,
  createTrack,
  createClip,
  calculateProjectDuration,
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
    },
    onActionError: (message) => log(`Timeline action failed: ${message}`),
  },
);

window.addEventListener("resize", () => {
  timelineUI.render();
});

function forceRepaint(): void {
  const el = document.body;
  const prevDisplay = el.style.display;
  el.style.display = "none";
  void el.offsetHeight;
  el.style.display = prevDisplay;
  window.scrollBy(0, 1);
  window.scrollBy(0, -1);
}

for (const eventName of ["fullscreenchange", "webkitfullscreenchange", "mozfullscreenchange", "MSFullscreenChange"]) {
  document.addEventListener(eventName, () => {
    forceRepaint();
    timelineUI.render();
  });
}

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
          let peakMin = Infinity;
          let peakMax = -Infinity;
          let peakSum = 0;
          for (let i = 0; i < waveform.peaks.length; i++) {
            const v = waveform.peaks[i];
            if (v < peakMin) peakMin = v;
            if (v > peakMax) peakMax = v;
            peakSum += v;
          }
          const peakAvg = waveform.peaks.length > 0 ? peakSum / waveform.peaks.length : 0;
          log(
            `Waveform ready. peaks: min=${peakMin.toFixed(4)} max=${peakMax.toFixed(4)} avg=${peakAvg.toFixed(4)} count=${waveform.peaks.length}`,
          );
        })
        .catch((e) => {
          log(`Waveform generation failed (clip plays fine, just no waveform): ${e instanceof Error ? e.message : String(e)}`);
        });
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
    // Thumbnails aren't shown anywhere in this UI yet, so those stay off.
    // Waveform analysis also stays off here — it scans the whole file and
    // used to run inline, blocking this handler on every import. It's
    // kicked off in the background further below instead, once import
    // itself has already finished and the clip is usable.
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
        let peakMin = Infinity;
        let peakMax = -Infinity;
        let peakSum = 0;
        for (let i = 0; i < waveform.peaks.length; i++) {
          const v = waveform.peaks[i];
          if (v < peakMin) peakMin = v;
          if (v > peakMax) peakMax = v;
          peakSum += v;
        }
        const peakAvg = waveform.peaks.length > 0 ? peakSum / waveform.peaks.length : 0;
        log(
          `Waveform ready. peaks: min=${peakMin.toFixed(4)} max=${peakMax.toFixed(4)} avg=${peakAvg.toFixed(4)} count=${waveform.peaks.length}`,
        );
      })
      .catch((e) => {
        log(`Waveform generation failed (clip plays fine, just no waveform): ${e instanceof Error ? e.message : String(e)}`);
      });

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
