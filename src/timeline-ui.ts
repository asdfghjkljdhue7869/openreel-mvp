import type { Project, Track, Clip, TextClip, Action } from "@openreel/core";
import {
  ActionExecutor,
  ActionHistory,
  calculateSnap,
  formatTimecode,
  DEFAULT_SNAP_SETTINGS,
  type SnapSettings,
} from "@openreel/core";

export interface TimelineUIElements {
  ruler: HTMLElement;
  tracks: HTMLElement;
  timecode: HTMLElement;
  context: HTMLElement;
  zoomSlider: HTMLInputElement;
  zoomInBtn: HTMLButtonElement;
  zoomOutBtn: HTMLButtonElement;
  undoBtn: HTMLButtonElement;
  redoBtn: HTMLButtonElement;
}

export interface TimelineUICallbacks {
  onSeek(time: number): void;
  onPlay(): void;
  onPause(): void;
  /** Fired after any executor-driven mutation (move/trim/split/delete/track
   * add/mute/lock/undo/redo) commits. `project` is the SAME object
   * reference passed into setProject()/addClipToTrack() — the executor
   * mutates it in place — handed back purely so callers that hold their
   * own `project` variable can keep it in sync without re-reading. */
  onProjectChanged(project: Project): void;
  /** The user clicked "+ clip" on a track's header — caller is
   * responsible for picking a file, importing it, and calling
   * addClipToTrack() once the media item exists in the library. */
  onAddClipToTrack(trackId: string): void;
  onAddTitle(params: {
    trackId: string;
    text: string;
    fontSize: number;
    color: string;
    start: number;
    duration: number;
  }): void;
  onUpdateTextClip(id: string, updates: { startTime?: number; duration?: number }): void;
  onDeleteTitle(id: string): void;
  /** Fires a specific, human-readable line for every committed mutation
   * (move/trim/split/delete/track add/mute/lock/undo/redo) — wire this to
   * your visible log panel so "what changed" is legible from the log
   * alone, without having to describe UI behavior back and forth. */
  onLog?(message: string): void;
  /** Optional — surfaces a validation/execution failure message (e.g. from
   * the action executor rejecting an out-of-bounds split). */
  onActionError?(message: string): void;
}

const MIN_CLIP_SECONDS = 0.1;
const MIN_ZOOM = 20;
const MAX_ZOOM = 240;
const DEFAULT_ZOOM = 60;

type DragMode = "move" | "trim-left" | "trim-right";
type ClipKind = "media" | "text";

interface DragState {
  mode: DragMode;
  kind: ClipKind;
  clipId: string;
  trackId: string;
  clipEl: HTMLElement;
  pointerStartX: number;
  startTimeAtDragStart: number;
  durationAtDragStart: number;
  inPointAtDragStart: number;
  outPointAtDragStart: number;
  draftStartTime: number;
  draftDuration: number;
  draftInPoint: number;
  draftOutPoint: number;
}

function makeAction(type: string, params: Record<string, unknown>): Action {
  return {
    id: `action-${Date.now()}-${Math.random().toString(36).slice(2, 9)}`,
    type,
    timestamp: Date.now(),
    params,
  };
}

export class TimelineUI {
  private project: Project | null = null;

  private getProjectFrameRate(): number {
    return this.project?.settings.frameRate ?? 30;
  }
  private textClips: TextClip[] = [];
  private currentTime = 0;
  private pixelsPerSecond = DEFAULT_ZOOM;
  private snapSettings: SnapSettings = { ...DEFAULT_SNAP_SETTINGS };
  private drag: DragState | null = null;
  private selectedClipId: string | null = null;
  private selectedKind: ClipKind | null = null;
  private titleFormTrackId: string | null = null;

  private readonly history = new ActionHistory();
  private readonly executor = new ActionExecutor(this.history);

  constructor(
    private readonly elements: TimelineUIElements,
    private readonly callbacks: TimelineUICallbacks,
  ) {
    this.elements.ruler.addEventListener("pointerdown", (e) => this.onRulerPointerDown(e));
    this.elements.ruler.addEventListener("click", (e) => this.onRulerPointerDown(e));
    this.elements.ruler.addEventListener("pointermove", (e) => this.onTimelineHover(e));
    this.elements.ruler.addEventListener("pointerleave", () => this.hideHoverTime());
    this.elements.tracks.addEventListener("pointermove", (e) => this.onTimelineHover(e));
    this.elements.tracks.addEventListener("pointerleave", () => this.hideHoverTime());
    this.elements.zoomSlider.min = String(MIN_ZOOM);
    this.elements.zoomSlider.max = String(MAX_ZOOM);
    this.elements.zoomSlider.step = "10";
    this.elements.zoomSlider.value = String(this.pixelsPerSecond);
    this.elements.zoomSlider.addEventListener("input", () => {
      this.setZoom(Number(this.elements.zoomSlider.value));
    });
    this.elements.zoomInBtn.addEventListener("click", () => this.setZoom(this.pixelsPerSecond + 20));
    this.elements.zoomOutBtn.addEventListener("click", () => this.setZoom(this.pixelsPerSecond - 20));
    this.elements.undoBtn.addEventListener("click", () => this.undo());
    this.elements.redoBtn.addEventListener("click", () => this.redo());
    this.history.subscribe(() => this.updateUndoRedoButtons());
    this.updateUndoRedoButtons();

    window.addEventListener("keydown", (e) => this.onKeyDown(e));
  }

  setProject(project: Project | null): void {
    this.project = project;
    this.selectedClipId = null;
    this.selectedKind = null;
    this.titleFormTrackId = null;
    this.render();
  }

  setTextClips(clips: TextClip[]): void {
    this.textClips = clips;
    this.renderTracks();
  }

  setCurrentTime(time: number): void {
    this.currentTime = time;
    this.updatePlayheadOnly();
    // Only the "Split at playhead" button's enabled state depends on the
    // moving playhead — everything else in the context panel (source
    // in/out fields, delete, ripple-delete) is static per-selection.
    // Calling the full renderContext() here (as this used to) tore the
    // whole panel's DOM down and rebuilt it on every animation frame
    // during playback, which meant a click's mousedown and mouseup could
    // land on two different (destroyed/recreated) elements and silently
    // never fire — split/delete/ripple-delete/source-in/out all appeared
    // completely unresponsive while anything was selected during playback.
    this.refreshSplitButtonState();
  }

  private refreshSplitButtonState(): void {
    if (this.selectedKind !== "media" || !this.selectedClipId) return;
    const btn = this.elements.context.querySelector<HTMLButtonElement>('[data-role="split-btn"]');
    if (!btn) return;
    const clip = this.findMediaClip(this.selectedClipId);
    if (!clip) return;
    const withinBounds = this.currentTime > clip.startTime && this.currentTime < clip.startTime + clip.duration;
    btn.disabled = !withinBounds;
    btn.title = withinBounds
      ? "Split this clip at the current playhead position (S)"
      : "Move the playhead inside this clip to split it";
  }

  setZoom(pixelsPerSecond: number): void {
    this.pixelsPerSecond = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, pixelsPerSecond));
    this.elements.zoomSlider.value = String(this.pixelsPerSecond);
    this.render();
  }

  addTrack(type: "video" | "audio" | "image" | "text"): void {
    if (!this.project) return;
    void this.runAction(makeAction("track/add", { trackType: type })).then((ok) => {
      if (ok) this.log(`Added ${type} track`);
    });
  }

  async addClipToTrack(
    project: Project,
    trackId: string,
    mediaId: string,
    startTime: number,
    duration?: number,
  ): Promise<void> {
    this.project = project;
    await this.runAction(
      makeAction("clip/add", { trackId, mediaId, startTime, duration }),
    );
  }

  undo(): void {
    if (!this.project || !this.history.canUndo()) return;
    const entry = this.history.peekUndo();
    void this.executor.undo(this.project).then((result) => {
      if (!result.success) {
        this.callbacks.onActionError?.(result.error?.message ?? "Nothing to undo");
        return;
      }
      this.log(`Undo: ${entry?.description ?? "action"}`);
      this.afterMutation();
    });
  }

  redo(): void {
    if (!this.project || !this.history.canRedo()) return;
    const entry = this.history.peekRedo();
    void this.executor.redo(this.project).then((result) => {
      if (!result.success) {
        this.callbacks.onActionError?.(result.error?.message ?? "Nothing to redo");
        return;
      }
      this.log(`Redo: ${entry?.description ?? "action"}`);
      this.afterMutation();
    });
  }

  private log(message: string): void {
    this.callbacks.onLog?.(`[timeline] ${message}`);
  }

  // Split (clip/split in action-executor.ts) trusts whatever `time` it's
  // given with no bounds-checking of its own — if that time is ever even
  // slightly outside the target clip's [startTime, startTime+duration)
  // range when the action actually runs, it silently produces a
  // zero/negative-duration clip or an overlapping pair rather than
  // erroring. Log the full resulting track state after every split so a
  // "weird" split has concrete before/after numbers instead of a guess.
  // Same idea as logSplitResult but reusable after any track-mutating
  // action (move, trim) — a move that only repositions one piece of a
  // previously-split clip can silently open a gap or overlap the next
  // clip, which looks "weird" in the UI with no obvious cause otherwise.
  private logTrackState(trackId: string, label: string): void {
    if (!this.project) return;
    const track = this.project.timeline.tracks.find((t) => t.id === trackId);
    if (!track) return;
    const clips = [...track.clips].sort((a, b) => a.startTime - b.startTime);
    const parts = clips.map((c) => {
      const end = c.startTime + c.duration;
      const flag = c.duration <= 0.001 ? " ZERO/NEGATIVE-DURATION" : "";
      return (
        `${c.id.slice(0, 8)}[start=${c.startTime.toFixed(3)} dur=${c.duration.toFixed(3)} ` +
        `end=${end.toFixed(3)} in=${c.inPoint.toFixed(3)} out=${c.outPoint.toFixed(3)}]${flag}`
      );
    });
    let anomalies = "";
    for (let i = 1; i < clips.length; i++) {
      const prevEnd = clips[i - 1].startTime + clips[i - 1].duration;
      const gap = clips[i].startTime - prevEnd;
      if (Math.abs(gap) > 0.001) {
        anomalies += ` GAP/OVERLAP ${gap.toFixed(3)}s between ${clips[i - 1].id.slice(0, 8)} and ${clips[i].id.slice(0, 8)}.`;
      }
    }
    this.log(
      `${label} -> track ${trackId.slice(0, 8)} now has ${clips.length} clip(s): ${parts.join(" | ")}${anomalies}`,
    );
  }

  private logSplitResult(trackId: string, requestedTime: number): void {
    if (!this.project) return;
    const track = this.project.timeline.tracks.find((t) => t.id === trackId);
    if (!track) {
      this.log(`Split at t=${requestedTime.toFixed(3)}s: track ${trackId.slice(0, 8)} not found after split.`);
      return;
    }
    const clips = [...track.clips].sort((a, b) => a.startTime - b.startTime);
    const parts = clips.map((c) => {
      const end = c.startTime + c.duration;
      const flag = c.duration <= 0.001 ? " ZERO/NEGATIVE-DURATION" : "";
      return (
        `${c.id.slice(0, 8)}[start=${c.startTime.toFixed(3)} dur=${c.duration.toFixed(3)} ` +
        `end=${end.toFixed(3)} in=${c.inPoint.toFixed(3)} out=${c.outPoint.toFixed(3)}]${flag}`
      );
    });
    let anomalies = "";
    for (let i = 1; i < clips.length; i++) {
      const prevEnd = clips[i - 1].startTime + clips[i - 1].duration;
      const gap = clips[i].startTime - prevEnd;
      if (Math.abs(gap) > 0.001) {
        anomalies += ` GAP/OVERLAP ${gap.toFixed(3)}s between ${clips[i - 1].id.slice(0, 8)} and ${clips[i].id.slice(0, 8)}.`;
      }
    }
    this.log(
      `Split requested at t=${requestedTime.toFixed(3)}s -> track ${trackId.slice(0, 8)} now has ${clips.length} clip(s): ${parts.join(" | ")}${anomalies}`,
    );
  }

  private updateUndoRedoButtons(): void {
    this.elements.undoBtn.disabled = !this.history.canUndo();
    this.elements.redoBtn.disabled = !this.history.canRedo();
    const undoEntry = this.history.peekUndo();
    this.elements.undoBtn.title = undoEntry ? `Undo ${undoEntry.description} (Ctrl+Z)` : "Nothing to undo";
    const redoEntry = this.history.peekRedo();
    this.elements.redoBtn.title = redoEntry ? `Redo ${redoEntry.description} (Ctrl+Shift+Z)` : "Nothing to redo";
  }

  private async runAction(action: Action): Promise<boolean> {
    if (!this.project) return false;
    const result = await this.executor.execute(action, this.project);
    if (!result.success) {
      this.callbacks.onActionError?.(result.error?.message ?? `Action ${action.type} failed`);
      return false;
    }
    this.afterMutation();
    return true;
  }

  private afterMutation(): void {
    if (!this.project) return;
    this.render();
    this.callbacks.onProjectChanged(this.project);
  }

  private getTimelineDuration(): number {
    if (!this.project) return 30;
    let maxEnd = 0;
    for (const track of this.project.timeline.tracks) {
      for (const clip of track.clips) {
        maxEnd = Math.max(maxEnd, clip.startTime + clip.duration);
      }
    }
    for (const tc of this.textClips) {
      maxEnd = Math.max(maxEnd, tc.startTime + tc.duration);
    }
    return Math.max(30, maxEnd + 10);
  }

  render(): void {
    this.renderRuler();
    this.renderTracks();
    this.updatePlayheadOnly();
    this.renderContext();
  }

  private renderRuler(): void {
    const duration = this.getTimelineDuration();
    const width = duration * this.pixelsPerSecond;
    this.elements.ruler.style.width = `${this.headerWidthPx + width}px`;
    this.elements.ruler.innerHTML = "";

    // Denser grids at high zoom would produce unreadable, overlapping
    // labels — space major ticks out as pixels-per-second grows.
    const step = this.pixelsPerSecond >= 120 ? 1 : this.pixelsPerSecond >= 60 ? 2 : 5;
    for (let t = 0; t <= duration; t += step) {
      const tick = document.createElement("div");
      tick.className = "timeline-ruler-tick";
      tick.style.left = `${this.headerWidthPx + t * this.pixelsPerSecond}px`;
      const label = document.createElement("span");
      label.className = "timeline-ruler-tick-label";
      label.textContent = formatTimecode(t, this.getProjectFrameRate()).slice(0, 8);
      tick.appendChild(label);
      this.elements.ruler.appendChild(tick);
    }
  }

  private renderTracks(): void {
    const tracksEl = this.elements.tracks;
    if (!this.project) {
      tracksEl.innerHTML = "";
      return;
    }
    const project = this.project;

    const duration = this.getTimelineDuration();
    const width = duration * this.pixelsPerSecond;
    tracksEl.innerHTML = "";
    tracksEl.style.position = "relative";
    tracksEl.style.width = `${this.headerWidthPx + width}px`;

    project.timeline.tracks.forEach((track, index) => {
      const trackEl = document.createElement("div");
      trackEl.className = "timeline-track" + (index % 2 === 1 ? " alt" : "");

      const header = document.createElement("div");
      header.className = "timeline-track-header";
      const nameRow = document.createElement("div");
      nameRow.className = "timeline-track-name-row";
      const nameEl = document.createElement("div");
      nameEl.className = "timeline-track-name";
      nameEl.textContent = track.name;
      const typeEl = document.createElement("div");
      typeEl.className = "timeline-track-type";
      typeEl.textContent = track.type;
      nameRow.append(nameEl, typeEl);

      // Mute/lock/add-clip all share one row — stacking them on separate
      // rows made the header taller than the track lane itself, which
      // pushed "+ clip"/"+ Title" out of alignment with the rest of the
      // track and made it easy to miss entirely.
      const actionsRow = document.createElement("div");
      actionsRow.className = "timeline-track-actions";
      actionsRow.appendChild(
        this.makeToggle("\u{1F507}", "\u{1F50A}", track.muted, "Mute track", () =>
          this.toggleTrackFlag(track.id, "muted"),
        ),
      );
      actionsRow.appendChild(
        this.makeToggle("\u{1F512}", "\u{1F513}", track.locked, "Lock track", () =>
          this.toggleTrackFlag(track.id, "locked"),
        ),
      );

      const addBtn = document.createElement("button");
      addBtn.className = "timeline-track-add-clip";
      if (track.type === "text") {
        addBtn.textContent = "+ Title";
        addBtn.title = "Add a title to this track";
        addBtn.addEventListener("click", () => this.openTitleForm(track.id));
      } else {
        addBtn.textContent = "+ clip";
        addBtn.title = `Import a media file onto ${track.name}`;
        addBtn.addEventListener("click", () => this.callbacks.onAddClipToTrack(track.id));
      }
      actionsRow.appendChild(addBtn);
      header.append(nameRow, actionsRow);

      const lane = document.createElement("div");
      lane.className = "timeline-track-lane";
      lane.style.width = `${width}px`;
      lane.addEventListener("pointerdown", (e) => {
        if (e.target !== lane) {
          this.log(
            `[scrub] lane pointerdown ignored — target was <${(e.target as HTMLElement)?.tagName ?? "?"} class="${(e.target as HTMLElement)?.className ?? "?"}">, not the lane itself`,
          );
          return;
        }
        this.clearSelection();
        this.onScrubPointerDown(e);
      });
      lane.addEventListener("click", (e) => {
        if (e.target !== lane) {
          this.log(
            `[scrub] lane click ignored — target was <${(e.target as HTMLElement)?.tagName ?? "?"} class="${(e.target as HTMLElement)?.className ?? "?"}">, not the lane itself`,
          );
          return;
        }
        this.clearSelection();
        this.onScrubPointerDown(e);
      });

      if (track.type === "text") {
        for (const tc of this.textClips.filter((c) => c.trackId === track.id)) {
          lane.appendChild(
            this.renderClipElement({
              id: tc.id,
              trackId: track.id,
              trackType: track.type,
              startTime: tc.startTime,
              duration: tc.duration,
              label: tc.text || "Title",
              kind: "text",
              locked: track.locked,
            }),
          );
        }
      } else {
        for (const clip of track.clips) {
          const mediaItem = project.mediaLibrary.items.find((m) => m.id === clip.mediaId);
          const waveformBars =
            mediaItem?.waveformData && mediaItem.waveformData.length > 0 && mediaItem.metadata.duration > 0
              ? this.computeWaveformBars(
                  mediaItem.waveformData,
                  mediaItem.metadata.duration,
                  clip.inPoint,
                  clip.outPoint,
                  clip.duration * this.pixelsPerSecond,
                )
              : undefined;
          lane.appendChild(
            this.renderClipElement({
              id: clip.id,
              trackId: track.id,
              trackType: track.type,
              startTime: clip.startTime,
              duration: clip.duration,
              label: clip.mediaId,
              kind: "media",
              locked: track.locked,
              inPoint: clip.inPoint,
              outPoint: clip.outPoint,
              waveformBars,
            }),
          );
        }
      }

      trackEl.append(header, lane);
      tracksEl.appendChild(trackEl);
    });

    // renderTracks() wipes the DOM on every call including mid-drag —
    // put the playhead back so it isn't missing for a frame.
    this.updatePlayheadOnly();
  }

  private toggleTrackFlag(trackId: string, flag: "muted" | "locked"): void {
    if (!this.project) return;
    const track = this.project.timeline.tracks.find((t) => t.id === trackId);
    if (!track) return;
    const type = flag === "muted" ? "track/mute" : "track/lock";
    const key = flag === "muted" ? "muted" : "locked";
    const willBe = !track[flag];
    void this.runAction(makeAction(type, { trackId, [key]: willBe })).then((ok) => {
      if (ok) {
        const verb = flag === "muted" ? (willBe ? "Muted" : "Unmuted") : willBe ? "Locked" : "Unlocked";
        this.log(`${verb} track "${track.name}"`);
      }
    });
  }

  private makeToggle(
    activeGlyph: string,
    inactiveGlyph: string,
    active: boolean,
    title: string,
    onClick: () => void,
  ): HTMLElement {
    const btn = document.createElement("button");
    btn.className = "timeline-track-toggle" + (active ? " active" : "");
    btn.textContent = active ? activeGlyph : inactiveGlyph;
    btn.title = title;
    btn.addEventListener("click", onClick);
    return btn;
  }

  private computeWaveformBars(
    peaks: Float32Array,
    sourceDuration: number,
    inPoint: number,
    outPoint: number,
    widthPx: number,
  ): number[] {
    // The engine's waveform analysis always scans the FULL source file at a
    // fixed sample rate, but MediaItem only keeps the raw peaks array (the
    // sample rate itself doesn't survive the ProcessedMedia -> MediaItem
    // conversion) — so peaks[i] maps proportionally across [0, sourceDuration]
    // rather than at a known fixed rate. Good enough for a visual indicator.
    if (sourceDuration <= 0 || peaks.length === 0) return [];
    const startIdx = Math.max(0, Math.floor((inPoint / sourceDuration) * peaks.length));
    const endIdx = Math.min(peaks.length, Math.ceil((outPoint / sourceDuration) * peaks.length));
    const sliceLen = Math.max(1, endIdx - startIdx);
    const barCount = Math.max(1, Math.min(240, Math.floor(widthPx / 2)));
    const bars: number[] = [];
    for (let i = 0; i < barCount; i++) {
      const from = startIdx + Math.floor((i / barCount) * sliceLen);
      const to = Math.max(from + 1, startIdx + Math.floor(((i + 1) / barCount) * sliceLen));
      let peak = 0;
      for (let j = from; j < to && j < endIdx; j++) {
        peak = Math.max(peak, Math.abs(peaks[j] ?? 0));
      }
      bars.push(Math.min(1, peak));
    }
    // Real-world audio rarely hits absolute peak amplitude 1.0 — rendering
    // bars against that fixed scale meant anything short of already-hot
    // audio looked like a flat row of minimum-height dashes. Normalize
    // against this slice's own loudest sample instead, so the waveform
    // always uses the full visual range regardless of source loudness.
    const maxBar = bars.reduce((m, b) => Math.max(m, b), 0);
    if (maxBar > 0.0001) {
      for (let i = 0; i < bars.length; i++) {
        bars[i] = bars[i] / maxBar;
      }
    }
    return bars;
  }

  private renderClipElement(opts: {
    id: string;
    trackId: string;
    trackType: string;
    startTime: number;
    duration: number;
    label: string;
    kind: ClipKind;
    locked: boolean;
    inPoint?: number;
    outPoint?: number;
    waveformBars?: number[];
  }): HTMLElement {
    const el = document.createElement("div");
    el.className =
      "timeline-clip" +
      (opts.kind === "text" ? " timeline-clip-text" : "") +
      (opts.id === this.selectedClipId ? " selected" : "");
    el.dataset.trackType = opts.trackType;
    el.dataset.clipId = opts.id;
    el.style.left = `${opts.startTime * this.pixelsPerSecond}px`;
    el.style.width = `${Math.max(opts.duration, MIN_CLIP_SECONDS) * this.pixelsPerSecond}px`;

    if (opts.waveformBars && opts.waveformBars.length > 0) {
      el.appendChild(this.buildWaveformSvg(opts.waveformBars));
    }

    const labelEl = document.createElement("span");
    labelEl.className = "timeline-clip-label";
    labelEl.textContent = opts.label;
    el.appendChild(labelEl);

    el.title = `${opts.label}\n${opts.startTime.toFixed(2)}s + ${opts.duration.toFixed(2)}s`;

    if (!opts.locked) {
      el.addEventListener("pointerdown", (e) =>
        this.onClipPointerDown(e, opts, "move", el),
      );

      const leftHandle = document.createElement("div");
      leftHandle.className = "timeline-clip-handle left";
      leftHandle.addEventListener("pointerdown", (e) => {
        e.stopPropagation();
        this.onClipPointerDown(e, opts, "trim-left", el);
      });

      const rightHandle = document.createElement("div");
      rightHandle.className = "timeline-clip-handle right";
      rightHandle.addEventListener("pointerdown", (e) => {
        e.stopPropagation();
        this.onClipPointerDown(e, opts, "trim-right", el);
      });

      el.append(leftHandle, rightHandle);
    } else {
      el.classList.add("locked");
    }

    return el;
  }

  private buildWaveformSvg(bars: number[]): SVGSVGElement {
    const svgNS = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(svgNS, "svg") as unknown as SVGSVGElement;
    svg.setAttribute("class", "timeline-clip-waveform");
    svg.setAttribute("viewBox", `0 0 ${bars.length} 100`);
    svg.setAttribute("preserveAspectRatio", "none");
    bars.forEach((amp, i) => {
      const h = Math.max(6, amp * 92);
      const rect = document.createElementNS(svgNS, "rect");
      rect.setAttribute("x", String(i));
      rect.setAttribute("y", String(50 - h / 2));
      rect.setAttribute("width", "0.7");
      rect.setAttribute("height", String(h));
      svg.appendChild(rect);
    });
    return svg;
  }

  // Must match .timeline-track-header's CSS width (theme-default.css) —
  // the playhead line is appended to .timeline-tracks directly, not to a
  // lane, so unlike clip elements (positioned relative to their own lane,
  // which already starts past the header) it needs this added explicitly
  // or it renders 132px left of the clip content it's pointing at.
  private readonly headerWidthPx = 132;

  private updatePlayheadOnly(): void {
    const rawLeft = this.currentTime * this.pixelsPerSecond;

    let playhead = this.elements.tracks.querySelector<HTMLElement>(".timeline-playhead");
    if (!playhead) {
      playhead = document.createElement("div");
      playhead.className = "timeline-playhead";
      playhead.addEventListener("pointerdown", (e) => this.onPlayheadPointerDown(e));
      this.elements.tracks.appendChild(playhead);
    }
    playhead.style.left = `${this.headerWidthPx + rawLeft}px`;
    playhead.style.height = `${this.elements.tracks.scrollHeight}px`;

    // A live timecode riding along at the playhead itself — so you can
    // read the current time where you're actually looking, not just in
    // the toolbar off to the side.
    let liveTime = this.elements.ruler.querySelector<HTMLElement>(".timeline-ruler-live-time");
    if (!liveTime) {
      liveTime = document.createElement("div");
      liveTime.className = "timeline-ruler-live-time";
      this.elements.ruler.appendChild(liveTime);
    }
    liveTime.style.left = `${this.headerWidthPx + rawLeft}px`;
    liveTime.textContent = formatTimecode(this.currentTime, this.getProjectFrameRate()).slice(0, 8);

    this.elements.timecode.textContent = formatTimecode(this.currentTime, this.getProjectFrameRate());
  }

  private onPlayheadPointerDown(e: PointerEvent): void {
    e.preventDefault();
    e.stopPropagation();
    const onMove = (moveEvent: PointerEvent) => {
      const rect = this.elements.ruler.getBoundingClientRect();
      const x = moveEvent.clientX - rect.left - this.headerWidthPx;
      this.callbacks.onSeek(Math.max(0, x / this.pixelsPerSecond));
    };
    const onUp = () => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
    };
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
  }

  // Shows the time under the mouse as it moves over the ruler or a track
  // lane, even without clicking — separate from the (red) live playhead
  // time label, which only reflects where playback/the playhead actually
  // is. Uses the ruler's own rect as the coordinate origin, same as every
  // click-to-seek handler, so this always agrees with where a click here
  // would actually land.
  private onTimelineHover(e: PointerEvent): void {
    const rect = this.elements.ruler.getBoundingClientRect();
    const rawX = e.clientX - rect.left;
    const x = rawX - this.headerWidthPx;
    if (x < 0) {
      this.hideHoverTime();
      return;
    }
    const time = x / this.pixelsPerSecond;
    let label = this.elements.ruler.querySelector<HTMLElement>(".timeline-ruler-hover-time");
    if (!label) {
      label = document.createElement("div");
      label.className = "timeline-ruler-hover-time";
      label.innerHTML = '<div class="timeline-ruler-hover-time-main"></div><div class="timeline-ruler-hover-time-sub"></div>';
      this.elements.ruler.appendChild(label);
    }
    label.style.left = `${rawX}px`;
    label.style.display = "flex";
    const clamped = Math.max(0, time);
    const hours = Math.floor(clamped / 3600);
    const minutes = Math.floor((clamped % 3600) / 60);
    const seconds = Math.floor(clamped % 60);
    const ms = Math.floor((clamped % 1) * 1000);
    const main = label.querySelector<HTMLElement>(".timeline-ruler-hover-time-main");
    if (main) {
      main.textContent =
        `${hours.toString().padStart(2, "0")}:${minutes.toString().padStart(2, "0")}:` +
        `${seconds.toString().padStart(2, "0")}.${ms.toString().padStart(3, "0")}`;
    }
    const frame = Math.floor(clamped * this.getProjectFrameRate());
    const sub = label.querySelector<HTMLElement>(".timeline-ruler-hover-time-sub");
    if (sub) sub.textContent = `frame ${frame}`;
  }

  private hideHoverTime(): void {
    const label = this.elements.ruler.querySelector<HTMLElement>(".timeline-ruler-hover-time");
    if (label) label.style.display = "none";
  }

    private onRulerPointerDown(e: MouseEvent): void {
    const rect = this.elements.ruler.getBoundingClientRect();
    const x = e.clientX - rect.left - this.headerWidthPx;
    const time = Math.max(0, x / this.pixelsPerSecond);
    this.log(
      `[scrub] ruler ${e.type} at x=${x.toFixed(1)}px -> t=${time.toFixed(3)}s (playhead was ${this.currentTime.toFixed(3)}s)`,
    );
    this.callbacks.onSeek(time);
  }

  private onScrubPointerDown(e: MouseEvent): void {
    // Must match the ruler's own coordinate origin, not the tracks
    // container's — .timeline-tracks includes each row's 132px
    // .timeline-track-header column (position: sticky; left: 0) in its
    // bounding rect, but the ruler sits only above the lane content. Using
    // tracks' rect here added ~132px of unsubtracted offset to every
    // click-to-seek in a track lane, landing the seek noticeably later
    // than where you actually clicked.
    const rect = this.elements.ruler.getBoundingClientRect();
    const x = e.clientX - rect.left - this.headerWidthPx;
    const time = Math.max(0, x / this.pixelsPerSecond);
    this.log(
      `[scrub] lane ${e.type} at x=${x.toFixed(1)}px -> t=${time.toFixed(3)}s (playhead was ${this.currentTime.toFixed(3)}s)`,
    );
    this.callbacks.onSeek(time);
  }

  private clearSelection(): void {
    if (!this.selectedClipId) return;
    this.selectedClipId = null;
    this.selectedKind = null;
    this.titleFormTrackId = null;
    this.renderTracks();
    this.renderContext();
  }

  // ============ Selection + drag ============

  private onClipPointerDown(
    e: PointerEvent,
    opts: {
      id: string;
      trackId: string;
      startTime: number;
      duration: number;
      kind: ClipKind;
      inPoint?: number;
      outPoint?: number;
    },
    mode: DragMode,
    clipEl: HTMLElement,
  ): void {
    e.preventDefault();
    e.stopPropagation();
    this.titleFormTrackId = null;
    this.selectedClipId = opts.id;
    this.selectedKind = opts.kind;
    this.renderTracks();
    this.renderContext();

    // renderTracks() just rebuilt every clip element (to apply the
    // "selected" class) — the `clipEl` passed in is now detached from the
    // DOM. Re-find the live element and drag THAT one, or the pointer
    // moves silently update a node nobody can see until the final
    // post-commit render snaps it into place.
    const liveClipEl =
      this.elements.tracks.querySelector<HTMLElement>(`[data-clip-id="${opts.id}"]`) ?? clipEl;
    liveClipEl.classList.add("dragging");

    this.drag = {
      mode,
      kind: opts.kind,
      clipId: opts.id,
      trackId: opts.trackId,
      clipEl: liveClipEl,
      pointerStartX: e.clientX,
      startTimeAtDragStart: opts.startTime,
      durationAtDragStart: opts.duration,
      inPointAtDragStart: opts.inPoint ?? 0,
      outPointAtDragStart: opts.outPoint ?? opts.duration,
      draftStartTime: opts.startTime,
      draftDuration: opts.duration,
      draftInPoint: opts.inPoint ?? 0,
      draftOutPoint: opts.outPoint ?? opts.duration,
    };

    try {
      (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
    } catch {
      // Pointer capture can legitimately fail (pointer already released,
      // synthetic/test-dispatched events, some touch edge cases) — the
      // drag still works fine via the window-level move/up listeners
      // below, capture is just an optimization so drags don't drop if the
      // pointer briefly leaves the element.
    }

    const onMove = (moveEvent: PointerEvent) => this.onDragPointerMove(moveEvent);
    const onUp = () => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
      liveClipEl.classList.remove("dragging");
      void this.commitDrag();
    };
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
  }

  private onDragPointerMove(e: PointerEvent): void {
    if (!this.drag || !this.project) return;
    const deltaSeconds = (e.clientX - this.drag.pointerStartX) / this.pixelsPerSecond;
    const track = this.project.timeline.tracks.find((t) => t.id === this.drag!.trackId);
    if (!track) return;

    if (this.drag.mode === "move") {
      const rawTime = Math.max(0, this.drag.startTimeAtDragStart + deltaSeconds);
      const snap = calculateSnap(
        rawTime,
        this.drag.clipId,
        this.project.timeline.tracks,
        this.currentTime,
        this.snapSettings,
        this.pixelsPerSecond,
        this.drag.durationAtDragStart,
      );
      this.drag.draftStartTime = snap.time;
    } else if (this.drag.mode === "trim-left") {
      const rawStart = Math.max(0, this.drag.startTimeAtDragStart + deltaSeconds);
      const maxStart =
        this.drag.startTimeAtDragStart + this.drag.durationAtDragStart - MIN_CLIP_SECONDS;
      const clampedStart = Math.min(rawStart, maxStart);
      const shift = clampedStart - this.drag.startTimeAtDragStart;
      this.drag.draftStartTime = clampedStart;
      this.drag.draftDuration = this.drag.durationAtDragStart - shift;
      if (this.drag.kind === "media") {
        this.drag.draftInPoint = Math.max(0, this.drag.inPointAtDragStart + shift);
      }
    } else {
      const rawDuration = this.drag.durationAtDragStart + deltaSeconds;
      this.drag.draftDuration = Math.max(MIN_CLIP_SECONDS, rawDuration);
      if (this.drag.kind === "media") {
        this.drag.draftOutPoint =
          this.drag.outPointAtDragStart + (this.drag.draftDuration - this.drag.durationAtDragStart);
      }
    }

    // Cheap live preview: reposition just this element, no full rebuild.
    this.drag.clipEl.style.left = `${this.drag.draftStartTime * this.pixelsPerSecond}px`;
    this.drag.clipEl.style.width = `${Math.max(this.drag.draftDuration, MIN_CLIP_SECONDS) * this.pixelsPerSecond}px`;
  }

  private async commitDrag(): Promise<void> {
    if (!this.drag) {
      this.drag = null;
      return;
    }
    const drag = this.drag;
    this.drag = null;

    const startChanged = drag.draftStartTime !== drag.startTimeAtDragStart;
    const durationChanged = drag.draftDuration !== drag.durationAtDragStart;
    if (!startChanged && !durationChanged) {
      this.render();
      return;
    }

    const shortId = drag.clipId.slice(0, 8);
    const fmt = (n: number) => n.toFixed(2);

    if (drag.kind === "text") {
      const updates: { startTime?: number; duration?: number } = {};
      if (startChanged) updates.startTime = drag.draftStartTime;
      if (durationChanged) updates.duration = drag.draftDuration;
      this.callbacks.onUpdateTextClip(drag.clipId, updates);
      this.log(
        `Moved/trimmed title ${shortId} (${drag.mode}): start ${fmt(drag.startTimeAtDragStart)}s->${fmt(drag.draftStartTime)}s, duration ${fmt(drag.durationAtDragStart)}s->${fmt(drag.draftDuration)}s`,
      );
      this.render();
      return;
    }

    if (!this.project) return;

    if (startChanged && durationChanged) {
      // Trim-left produces both a position change and an in-point change —
      // group them so a single undo reverts both atomically.
      this.history.beginGroup();
      await this.executor.execute(
        makeAction("clip/move", { clipId: drag.clipId, startTime: drag.draftStartTime }),
        this.project,
      );
      const trimParams =
        drag.mode === "trim-left"
          ? { clipId: drag.clipId, inPoint: drag.draftInPoint }
          : { clipId: drag.clipId, outPoint: drag.draftOutPoint };
      await this.executor.execute(makeAction("clip/trim", trimParams), this.project);
      this.history.endGroup();
      this.log(
        `Trimmed clip ${shortId} (${drag.mode}): start ${fmt(drag.startTimeAtDragStart)}s->${fmt(drag.draftStartTime)}s, duration ${fmt(drag.durationAtDragStart)}s->${fmt(drag.draftDuration)}s`,
      );
      this.afterMutation();
      this.logTrackState(drag.trackId, "Trim result");
    } else if (startChanged) {
      const ok = await this.runAction(
        makeAction("clip/move", { clipId: drag.clipId, startTime: drag.draftStartTime }),
      );
      if (ok) {
        this.log(`Moved clip ${shortId}: start ${fmt(drag.startTimeAtDragStart)}s->${fmt(drag.draftStartTime)}s`);
        this.logTrackState(drag.trackId, "Move result");
      }
    } else {
      const trimParams =
        drag.mode === "trim-left"
          ? { clipId: drag.clipId, inPoint: drag.draftInPoint }
          : { clipId: drag.clipId, outPoint: drag.draftOutPoint };
      const ok = await this.runAction(makeAction("clip/trim", trimParams));
      if (ok) {
        this.log(
          `Trimmed clip ${shortId} (${drag.mode}): duration ${fmt(drag.durationAtDragStart)}s->${fmt(drag.draftDuration)}s`,
        );
        this.logTrackState(drag.trackId, "Trim result");
      }
    }
  }

  // ============ Contextual panel: selected clip / add-title form ============

  private openTitleForm(trackId: string): void {
    this.selectedClipId = null;
    this.selectedKind = null;
    this.titleFormTrackId = trackId;
    this.renderContext();
  }

  private field(label: string): { wrap: HTMLElement; input: HTMLInputElement } {
    const wrap = document.createElement("div");
    wrap.className = "field field-narrow";
    const labelEl = document.createElement("label");
    labelEl.textContent = label;
    const input = document.createElement("input");
    labelEl.htmlFor = "";
    wrap.append(labelEl, input);
    return { wrap, input };
  }

  private renderContext(): void {
    const el = this.elements.context;
    el.innerHTML = "";

    if (this.titleFormTrackId) {
      el.classList.add("visible");
      el.appendChild(this.buildTitleForm(this.titleFormTrackId));
      return;
    }

    if (this.selectedClipId && this.selectedKind === "media" && this.project) {
      const clip = this.findMediaClip(this.selectedClipId);
      if (clip) {
        el.classList.add("visible");
        el.appendChild(this.buildMediaClipPanel(clip));
        return;
      }
    }

    if (this.selectedClipId && this.selectedKind === "text") {
      const tc = this.textClips.find((c) => c.id === this.selectedClipId);
      if (tc) {
        el.classList.add("visible");
        el.appendChild(this.buildTextClipPanel(tc));
        return;
      }
    }

    el.classList.remove("visible");
  }

  private findMediaClip(clipId: string): Clip | null {
    if (!this.project) return null;
    for (const track of this.project.timeline.tracks) {
      const clip = track.clips.find((c) => c.id === clipId);
      if (clip) return clip;
    }
    return null;
  }

  private buildTitleForm(trackId: string): HTMLElement {
    const wrap = document.createElement("div");
    wrap.className = "timeline-context-row";

    const label = document.createElement("span");
    label.className = "timeline-context-label";
    label.textContent = "Add title";
    wrap.appendChild(label);

    const text = this.field("Text");
    text.input.type = "text";
    text.input.placeholder = "Title text\u2026";
    text.wrap.classList.add("field-grow");

    const fontSize = this.field("Font size");
    fontSize.input.type = "number";
    fontSize.input.value = "48";
    fontSize.input.min = "8";
    fontSize.input.max = "300";

    const colorWrap = document.createElement("div");
    colorWrap.className = "field field-swatch";
    const colorLabel = document.createElement("label");
    colorLabel.textContent = "Color";
    const color = document.createElement("input");
    color.type = "color";
    color.value = "#ffffff";
    colorWrap.append(colorLabel, color);

    const start = this.field("Start (s)");
    start.input.type = "number";
    start.input.step = "0.1";
    start.input.min = "0";
    start.input.value = this.currentTime.toFixed(2);

    const duration = this.field("Duration (s)");
    duration.input.type = "number";
    duration.input.step = "0.1";
    duration.input.min = "0.1";
    duration.input.value = "3";

    const addBtn = document.createElement("button");
    addBtn.className = "primary touch-target";
    addBtn.textContent = "Add";
    addBtn.addEventListener("click", () => {
      const t = text.input.value.trim();
      if (!t) {
        text.input.focus();
        return;
      }
      this.callbacks.onAddTitle({
        trackId,
        text: t,
        fontSize: parseInt(fontSize.input.value, 10) || 48,
        color: color.value,
        start: parseFloat(start.input.value) || 0,
        duration: parseFloat(duration.input.value) || 3,
      });
      this.titleFormTrackId = null;
      this.renderContext();
    });

    const cancelBtn = document.createElement("button");
    cancelBtn.className = "touch-target";
    cancelBtn.textContent = "Cancel";
    cancelBtn.addEventListener("click", () => {
      this.titleFormTrackId = null;
      this.renderContext();
    });

    wrap.append(text.wrap, fontSize.wrap, colorWrap, start.wrap, duration.wrap, addBtn, cancelBtn);
    return wrap;
  }

  private buildMediaClipPanel(clip: Clip): HTMLElement {
    const wrap = document.createElement("div");
    wrap.className = "timeline-context-row";

    const label = document.createElement("span");
    label.className = "timeline-context-label";
    label.textContent = clip.mediaId;
    wrap.appendChild(label);

    const inField = this.field("Source in (s)");
    inField.input.type = "number";
    inField.input.step = "0.1";
    inField.input.min = "0";
    inField.input.value = clip.inPoint.toFixed(2);
    inField.input.title = "Adjusts what part of the source plays here — does not move the clip.";
    inField.input.addEventListener("change", () => {
      const v = parseFloat(inField.input.value);
      if (isNaN(v) || v < 0 || v >= clip.outPoint) {
        inField.input.value = clip.inPoint.toFixed(2);
        return;
      }
      void this.runAction(makeAction("clip/trim", { clipId: clip.id, inPoint: v })).then((ok) => {
        if (ok) this.log(`Set source in on clip ${clip.id.slice(0, 8)}: ${clip.inPoint.toFixed(2)}s->${v.toFixed(2)}s`);
      });
    });

    const outField = this.field("Source out (s)");
    outField.input.type = "number";
    outField.input.step = "0.1";
    outField.input.min = "0";
    outField.input.value = clip.outPoint.toFixed(2);
    outField.input.title = "Adjusts how much of the source plays here — does not move the clip.";
    outField.input.addEventListener("change", () => {
      const v = parseFloat(outField.input.value);
      if (isNaN(v) || v <= clip.inPoint) {
        outField.input.value = clip.outPoint.toFixed(2);
        return;
      }
      void this.runAction(makeAction("clip/trim", { clipId: clip.id, outPoint: v })).then((ok) => {
        if (ok) this.log(`Set source out on clip ${clip.id.slice(0, 8)}: ${clip.outPoint.toFixed(2)}s->${v.toFixed(2)}s`);
      });
    });

    const withinBounds =
      this.currentTime > clip.startTime && this.currentTime < clip.startTime + clip.duration;

    const splitBtn = document.createElement("button");
    splitBtn.className = "touch-target";
    splitBtn.textContent = "Split at playhead";
    splitBtn.dataset.role = "split-btn";
    splitBtn.disabled = !withinBounds;
    splitBtn.title = withinBounds
      ? "Split this clip at the current playhead position (S)"
      : "Move the playhead inside this clip to split it";
    splitBtn.addEventListener("click", () => {
      const t = this.currentTime;
      void this.runAction(makeAction("clip/split", { clipId: clip.id, time: t })).then((ok) => {
        if (ok) this.logSplitResult(clip.trackId, t);
      });
    });

    const deleteBtn = document.createElement("button");
    deleteBtn.className = "touch-target";
    deleteBtn.textContent = "Delete";
    deleteBtn.title = "Delete clip, leaving a gap (Delete)";
    deleteBtn.addEventListener("click", () => this.deleteSelected(false));

    const rippleBtn = document.createElement("button");
    rippleBtn.className = "touch-target";
    rippleBtn.textContent = "Ripple delete";
    rippleBtn.title = "Delete clip and shift later clips on this track left (Shift+Delete)";
    rippleBtn.addEventListener("click", () => this.deleteSelected(true));

    wrap.append(inField.wrap, outField.wrap, splitBtn, deleteBtn, rippleBtn);
    return wrap;
  }

  private buildTextClipPanel(tc: TextClip): HTMLElement {
    const wrap = document.createElement("div");
    wrap.className = "timeline-context-row";

    const label = document.createElement("span");
    label.className = "timeline-context-label";
    label.textContent = tc.text || "Title";
    wrap.appendChild(label);

    const startField = this.field("Start (s)");
    startField.input.type = "number";
    startField.input.step = "0.1";
    startField.input.min = "0";
    startField.input.value = tc.startTime.toFixed(2);
    startField.input.addEventListener("change", () => {
      const v = parseFloat(startField.input.value);
      if (isNaN(v) || v < 0) {
        startField.input.value = tc.startTime.toFixed(2);
        return;
      }
      this.callbacks.onUpdateTextClip(tc.id, { startTime: v });
    });

    const durationField = this.field("Duration (s)");
    durationField.input.type = "number";
    durationField.input.step = "0.1";
    durationField.input.min = "0.1";
    durationField.input.value = tc.duration.toFixed(2);
    durationField.input.addEventListener("change", () => {
      const v = parseFloat(durationField.input.value);
      if (isNaN(v) || v <= 0) {
        durationField.input.value = tc.duration.toFixed(2);
        return;
      }
      this.callbacks.onUpdateTextClip(tc.id, { duration: v });
    });

    const deleteBtn = document.createElement("button");
    deleteBtn.className = "touch-target";
    deleteBtn.textContent = "Delete";
    deleteBtn.addEventListener("click", () => this.deleteSelected(false));

    wrap.append(startField.wrap, durationField.wrap, deleteBtn);
    return wrap;
  }

  private deleteSelected(ripple: boolean): void {
    if (!this.selectedClipId) return;
    if (this.selectedKind === "text") {
      const id = this.selectedClipId;
      this.callbacks.onDeleteTitle(id);
      this.log(`Deleted title ${id.slice(0, 8)}`);
      this.selectedClipId = null;
      this.selectedKind = null;
      this.render();
      return;
    }
    const type = ripple ? "clip/rippleDelete" : "clip/remove";
    const id = this.selectedClipId;
    void this.runAction(makeAction(type, { clipId: id })).then((ok) => {
      if (ok) {
        this.log(`${ripple ? "Ripple-deleted" : "Deleted"} clip ${id.slice(0, 8)}`);
      }
      if (ok && this.selectedClipId === id) {
        this.selectedClipId = null;
        this.selectedKind = null;
        this.render();
      }
    });
  }

  // ============ Keyboard shortcuts ============

  private onKeyDown(e: KeyboardEvent): void {
    const active = document.activeElement;
    const isEditable =
      active instanceof HTMLInputElement ||
      active instanceof HTMLTextAreaElement ||
      active instanceof HTMLSelectElement ||
      (active instanceof HTMLElement && active.isContentEditable);
    if (isEditable) return;

    const mod = e.ctrlKey || e.metaKey;

    if (mod && e.key.toLowerCase() === "z") {
      e.preventDefault();
      if (e.shiftKey) this.redo();
      else this.undo();
      return;
    }
    if (mod && e.key.toLowerCase() === "y") {
      e.preventDefault();
      this.redo();
      return;
    }

    switch (e.key) {
      case " ":
        e.preventDefault();
        this.callbacks.onPlay();
        return;
      case "k":
      case "K":
        this.callbacks.onPause();
        return;
      case "l":
      case "L":
        this.callbacks.onPlay();
        return;
      case "j":
      case "J":
        // Reverse playback isn't supported by the engine — this nudges
        // the playhead back a second instead of true J-shuttle.
        this.callbacks.onSeek(Math.max(0, this.currentTime - 1));
        return;
      case "s":
      case "S":
        if (this.selectedClipId && this.selectedKind === "media") {
          const clip = this.findMediaClip(this.selectedClipId);
          if (clip && this.currentTime > clip.startTime && this.currentTime < clip.startTime + clip.duration) {
            const t = this.currentTime;
            void this.runAction(makeAction("clip/split", { clipId: clip.id, time: t })).then((ok) => {
              if (ok) this.logSplitResult(clip.trackId, t);
            });
          }
        }
        return;
      case "Delete":
      case "Backspace":
        if (this.selectedClipId) {
          e.preventDefault();
          this.deleteSelected(e.shiftKey);
        }
        return;
      case "Escape":
        this.clearSelection();
        return;
      case "ArrowLeft":
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
  }

  private nudgeSelected(delta: number): void {
    if (!this.selectedClipId) return;
    if (this.selectedKind === "text") {
      const tc = this.textClips.find((c) => c.id === this.selectedClipId);
      if (!tc) return;
      const newStart = Math.max(0, tc.startTime + delta);
      this.callbacks.onUpdateTextClip(tc.id, { startTime: newStart });
      this.log(`Nudged title ${tc.id.slice(0, 8)}: ${tc.startTime.toFixed(2)}s->${newStart.toFixed(2)}s`);
      return;
    }
    const clip = this.findMediaClip(this.selectedClipId);
    if (!clip) return;
    const newStart = Math.max(0, clip.startTime + delta);
    void this.runAction(makeAction("clip/move", { clipId: clip.id, startTime: newStart })).then((ok) => {
      if (ok) this.log(`Nudged clip ${clip.id.slice(0, 8)}: ${clip.startTime.toFixed(2)}s->${newStart.toFixed(2)}s`);
    });
  }
}
