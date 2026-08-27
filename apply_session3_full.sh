mkdir -p src
cat > src/timeline-ui.ts <<'OPENREEL_APPLY_EOF'
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
    this.elements.ruler.style.width = `${width}px`;
    this.elements.ruler.innerHTML = "";

    // Denser grids at high zoom would produce unreadable, overlapping
    // labels — space major ticks out as pixels-per-second grows.
    const step = this.pixelsPerSecond >= 120 ? 1 : this.pixelsPerSecond >= 60 ? 2 : 5;
    for (let t = 0; t <= duration; t += step) {
      const tick = document.createElement("div");
      tick.className = "timeline-ruler-tick";
      tick.style.left = `${t * this.pixelsPerSecond}px`;
      const label = document.createElement("span");
      label.className = "timeline-ruler-tick-label";
      label.textContent = formatTimecode(t, 30).slice(0, 8);
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
        if (e.target !== lane) return;
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

  private updatePlayheadOnly(): void {
    const left = this.currentTime * this.pixelsPerSecond;

    let playhead = this.elements.tracks.querySelector<HTMLElement>(".timeline-playhead");
    if (!playhead) {
      playhead = document.createElement("div");
      playhead.className = "timeline-playhead";
      playhead.addEventListener("pointerdown", (e) => this.onPlayheadPointerDown(e));
      this.elements.tracks.appendChild(playhead);
    }
    playhead.style.left = `${left}px`;
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
    liveTime.style.left = `${left}px`;
    liveTime.textContent = formatTimecode(this.currentTime, 30).slice(0, 8);

    this.elements.timecode.textContent = formatTimecode(this.currentTime, 30);
  }

  private onPlayheadPointerDown(e: PointerEvent): void {
    e.preventDefault();
    e.stopPropagation();
    const onMove = (moveEvent: PointerEvent) => {
      const rect = this.elements.ruler.getBoundingClientRect();
      const x = moveEvent.clientX - rect.left;
      this.callbacks.onSeek(Math.max(0, x / this.pixelsPerSecond));
    };
    const onUp = () => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
    };
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
  }

  private onRulerPointerDown(e: PointerEvent): void {
    const rect = this.elements.ruler.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const time = Math.max(0, x / this.pixelsPerSecond);
    this.callbacks.onSeek(time);
  }

  private onScrubPointerDown(e: PointerEvent): void {
    const rect = this.elements.tracks.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const time = Math.max(0, x / this.pixelsPerSecond);
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
    } else if (startChanged) {
      const ok = await this.runAction(
        makeAction("clip/move", { clipId: drag.clipId, startTime: drag.draftStartTime }),
      );
      if (ok) {
        this.log(`Moved clip ${shortId}: start ${fmt(drag.startTimeAtDragStart)}s->${fmt(drag.draftStartTime)}s`);
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
        if (ok) this.log(`Split clip ${clip.id.slice(0, 8)} at ${t.toFixed(2)}s`);
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
              if (ok) this.log(`Split clip ${clip.id.slice(0, 8)} at ${t.toFixed(2)}s`);
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
OPENREEL_APPLY_EOF
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
    // Thumbnails aren't shown anywhere in this UI yet, so those stay off —
    // but the timeline now renders a waveform on every clip, so waveform
    // analysis (100 samples/sec across the file) needs to run at import
    // time. This does add real time on longer files.
    const importStart = performance.now();
    const result = await importService.importMedia(file, {
      generateThumbnails: false,
      generateWaveform: true,
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
cat > src/index.html <<'OPENREEL_APPLY_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>OpenReel MVP — Premiere in a Browser</title>
</head>
<body>
  <div class="app-layout">

    <header class="area-header">
      <h1>OpenReel MVP</h1>
      <div class="sub">Real engine, no mockups: import → scrub → trim → export, running on @openreel/core.</div>
    </header>

    <section class="area-preview panel">
      <input type="file" id="fileInput" accept="video/*">
      <canvas id="canvas" width="960" height="540"></canvas>

      <div class="controls">
        <button id="playBtn" disabled class="touch-target">Play</button>
        <input type="range" id="seekBar" min="0" max="100" value="0" step="0.01" disabled>
        <span id="timeLabel">0.00s / 0.00s</span>
      </div>
    </section>

    <div class="area-panels">

      <section class="panel">
        <p class="panel-title">Theme</p>
        <div class="controls">
          <div class="field field-grow">
            <label for="themeUrlInput">Theme CSS URL</label>
            <input type="text" id="themeUrlInput" placeholder="https://example.com/my-theme.css">
          </div>
          <button id="loadThemeBtn" class="touch-target">Load Theme</button>
          <button id="resetThemeBtn" class="touch-target">Reset to Default</button>
        </div>
      </section>

    </div>

    <section class="area-actions">
      <div class="controls">
        <button id="exportBtn" disabled class="primary touch-target">Export MP4</button>
        <button id="resetBtn" class="touch-target">Reset (free memory)</button>
        <label class="touch-target" style="display:inline-flex;align-items:center;gap:6px;font-size:0.8rem;">
          <input type="checkbox" id="preferSoftwareEncodingCheckbox">
          Prefer software encoding (skip hardware attempt)
        </label>
        <span id="status" class="idle">Waiting for a video…</span>
      </div>
    </section>

    <section class="area-timeline">
      <div class="timeline" id="timelinePanel">
        <div class="timeline-toolbar">
          <button id="addVideoTrackBtn" class="touch-target">+ Video Track</button>
          <button id="addAudioTrackBtn" class="touch-target">+ Audio Track</button>
          <button id="addTextTrackBtn" class="touch-target">+ Text Track</button>
          <div class="timeline-toolbar-spacer"></div>
          <div class="timeline-zoom" title="Timeline zoom">
            <button id="timelineZoomOutBtn" class="touch-target" title="Zoom out">&minus;</button>
            <input type="range" id="timelineZoomSlider" min="20" max="240" step="10" value="60">
            <button id="timelineZoomInBtn" class="touch-target" title="Zoom in">+</button>
          </div>
          <button id="timelineUndoBtn" class="touch-target" title="Undo (Ctrl+Z)">&#8630;</button>
          <button id="timelineRedoBtn" class="touch-target" title="Redo (Ctrl+Shift+Z)">&#8631;</button>
          <span class="timecode" id="timelineTimecode">00:00:00:00</span>
        </div>
        <div class="timeline-context" id="timelineContext"></div>
        <div class="timeline-scroll" id="timelineScroll">
          <div class="timeline-ruler" id="timelineRuler"></div>
          <div class="timeline-tracks" id="timelineTracks"></div>
        </div>
      </div>
    </section>

    <section class="area-log">
      <div id="log"></div>
    </section>

  </div>

  <script type="module" src="./main.ts"></script>
</body>
</html>
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
  width: 9px;
  margin-left: -4px;
  z-index: 4;
  cursor: ew-resize;
}

.timeline-playhead::after {
  content: "";
  position: absolute;
  top: 0;
  bottom: 0;
  left: 4px;
  width: 1px;
  background: var(--danger);
  box-shadow: 0 0 4px color-mix(in srgb, var(--danger) 60%, transparent);
}

.timeline-playhead::before {
  content: "";
  position: absolute;
  top: 0;
  left: -1px;
  border-left: 5px solid transparent;
  border-right: 5px solid transparent;
  border-top: 6px solid var(--danger);
}

.timeline-ruler-live-time {
  position: absolute;
  top: 1px;
  transform: translateX(2px);
  background: var(--danger);
  color: #fff;
  font-family: var(--font-mono);
  font-size: 0.6rem;
  line-height: 1.3;
  padding: 0 4px;
  border-radius: 2px;
  white-space: nowrap;
  pointer-events: none;
  z-index: 5;
}

.timeline-clip-waveform {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  pointer-events: none;
  opacity: 0.45;
}

.timeline-clip-waveform rect {
  fill: currentColor;
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
echo "openreel-mvp: session 3 timeline work applied (full bundle)."
