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
const inPointInput = $<HTMLInputElement>("inPoint");
const outPointInput = $<HTMLInputElement>("outPoint");
const applyTrimBtn = $<HTMLButtonElement>("applyTrimBtn");
const exportBtn = $<HTMLButtonElement>("exportBtn");
const titleText = $<HTMLInputElement>("titleText");
const titleFontSize = $<HTMLInputElement>("titleFontSize");
const titleColor = $<HTMLInputElement>("titleColor");
const titleStart = $<HTMLInputElement>("titleStart");
const titleDuration = $<HTMLInputElement>("titleDuration");
const addTitleBtn = $<HTMLButtonElement>("addTitleBtn");
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
    inPointInput.disabled = false;
    outPointInput.disabled = false;
    applyTrimBtn.disabled = false;
    exportBtn.disabled = false;
    titleText.disabled = false;
    titleFontSize.disabled = false;
    titleColor.disabled = false;
    titleStart.disabled = false;
    titleDuration.disabled = false;
    addTitleBtn.disabled = false;
    inPointInput.value = "0";
    outPointInput.value = sourceDuration.toFixed(2);

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

playBtn.addEventListener("click", async () => {
  if (!playback) return;
  if (playback.isPlaying()) {
    playback.pause();
    playBtn.textContent = "Play";
  } else {
    await playback.play();
    playBtn.textContent = "Pause";
    const statsInterval = setInterval(() => {
      if (!playback || !playback.isPlaying()) {
        clearInterval(statsInterval);
        return;
      }
      const stats = playback.getStats();
      log(`stats: ${JSON.stringify(stats)}`);
    }, 2000);
  }
});

seekBar.addEventListener("input", async () => {
  if (!playback) return;
  await playback.seek(parseFloat(seekBar.value));
});

applyTrimBtn.addEventListener("click", async () => {
  if (!project || !track || !clip || !playback) return;
  const inPt = parseFloat(inPointInput.value);
  const outPt = parseFloat(outPointInput.value);
  if (isNaN(inPt) || isNaN(outPt) || outPt <= inPt || outPt > sourceDuration || inPt < 0) {
    log(`Invalid trim range: in=${inPt}, out=${outPt} (source duration ${sourceDuration.toFixed(2)}s)`);
    return;
  }

  // Pause and let any in-flight render finish before swapping the project —
  // applying a new timeline underneath a live playback loop is exactly the
  // kind of race that produces stuck/mismatched UI state.
  const wasPlaying = playback.isPlaying();
  if (wasPlaying) playback.pause();
  playBtn.textContent = "Play";

  const trimmedClip: Clip = {
    ...clip,
    inPoint: inPt,
    outPoint: outPt,
    duration: outPt - inPt,
  };
  clip = trimmedClip;
  track = { ...track, clips: [trimmedClip] };
  project = {
    ...project,
    modifiedAt: Date.now(),
    timeline: { ...project.timeline, tracks: textTrack ? [track, textTrack] : [track], duration: trimmedClip.duration },
  };

  playback.setProject(project);

  // The trimmed clip has a new, shorter duration — every piece of UI that
  // referenced the old duration needs to be refreshed, not just the engine.
  sourceDuration = trimmedClip.duration;
  seekBar.max = String(sourceDuration);
  seekBar.value = "0";
  timeLabel.textContent = `0.00s / ${sourceDuration.toFixed(2)}s`;
  await playback.seek(0);

  log(`Trim applied: in=${inPt.toFixed(2)}s out=${outPt.toFixed(2)}s duration=${trimmedClip.duration.toFixed(2)}s`);
});

addTitleBtn.addEventListener("click", () => {
  if (!project || !textTrack) return;
  const text = titleText.value.trim();
  if (!text) {
    log("Enter some title text first.");
    return;
  }

  const start = parseFloat(titleStart.value) || 0;
  const duration = parseFloat(titleDuration.value) || 3;
  const fontSize = parseInt(titleFontSize.value, 10) || DEFAULT_TEXT_STYLE.fontSize;
  const color = titleColor.value || DEFAULT_TEXT_STYLE.color;

  const textClip = titleEngine.createTextClip({
    trackId: textTrack.id,
    startTime: start,
    duration,
    text,
    style: { ...DEFAULT_TEXT_STYLE, fontSize, color },
  });

  playback?.setProject(project);
  log(`Title added: "${text}" at ${start.toFixed(2)}s for ${duration.toFixed(2)}s (clip id ${textClip.id}).`);
});

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
  setStatus("Exporting…", "working");

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
    while (true) {
      const step = await generator.next();
      if (step.done) {
        result = step.value;
        break;
      }
      const p = step.value;
      setStatus(`Exporting… ${Math.round((p.currentFrame / Math.max(p.totalFrames, 1)) * 100)}%`, "working");
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
  project = null;
  track = null;
  clip = null;
  textTrack = null;
  mediaId = null;
  sourceDuration = 0;

  const ctx = canvas.getContext("2d");
  ctx?.clearRect(0, 0, canvas.width, canvas.height);
  seekBar.value = "0";
  seekBar.disabled = true;
  playBtn.disabled = true;
  playBtn.textContent = "Play";
  inPointInput.disabled = true;
  outPointInput.disabled = true;
  applyTrimBtn.disabled = true;
  exportBtn.disabled = true;
  titleText.disabled = true;
  titleText.value = "";
  titleFontSize.disabled = true;
  titleColor.disabled = true;
  titleStart.disabled = true;
  titleDuration.disabled = true;
  addTitleBtn.disabled = true;
  fileInput.value = "";
  timeLabel.textContent = "0.00s / 0.00s";
  setStatus("Waiting for a video…", "idle");
  log("--- Reset: engines disposed, memory freed. Pick a new file to start fresh. ---");
});
