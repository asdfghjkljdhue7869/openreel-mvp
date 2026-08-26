import type { Project, Track, Clip } from "@openreel/core";
import {
  createTrack,
  calculateSnap,
  formatTimecode,
  DEFAULT_SNAP_SETTINGS,
  type SnapSettings,
} from "@openreel/core";

export interface TimelineUICallbacks {
  onSeek(time: number): void;
  /** Called with a brand-new Project reference after any commit (clip
   * moved/trimmed, track added, track muted/locked toggled) — mirrors
   * main.ts's own applyTrimBtn handler: rebuild immutably, hand back the
   * new object, caller re-points playback.setProject() at it. */
  onProjectChanged(project: Project): void;
  /** The user clicked "+ clip" on a track's header — caller is
   * responsible for picking a file, importing it, and building/appending
   * the resulting Clip (timeline-ui.ts has no media-import access itself). */
  onAddClipToTrack(trackId: string): void;
}

const PIXELS_PER_SECOND = 60;
const MIN_CLIP_SECONDS = 0.1;

type DragMode = "move" | "trim-left" | "trim-right";

interface DragState {
  mode: DragMode;
  clipId: string;
  trackId: string;
  clipEl: HTMLElement;
  pointerStartX: number;
  startTimeAtDragStart: number;
  durationAtDragStart: number;
  inPointAtDragStart: number;
  outPointAtDragStart: number;
  // Live values while dragging — only committed into a new immutable
  // Project object on pointerup.
  draftStartTime: number;
  draftDuration: number;
  draftInPoint: number;
  draftOutPoint: number;
}

export class TimelineUI {
  private project: Project | null = null;
  private currentTime = 0;
  private snapSettings: SnapSettings = { ...DEFAULT_SNAP_SETTINGS };
  private drag: DragState | null = null;
  private selectedClipId: string | null = null;

  constructor(
    private readonly rulerEl: HTMLElement,
    private readonly tracksEl: HTMLElement,
    private readonly timecodeEl: HTMLElement | null,
    private readonly callbacks: TimelineUICallbacks,
  ) {
    this.rulerEl.addEventListener("pointerdown", (e) => this.onRulerPointerDown(e));
  }

  setProject(project: Project | null): void {
    this.project = project;
    this.selectedClipId = null;
    this.render();
  }

  setCurrentTime(time: number): void {
    this.currentTime = time;
    this.updatePlayheadOnly();
  }

  addTrack(type: "video" | "audio" | "image"): void {
    if (!this.project) return;
    const track = createTrack(type);
    const updated: Project = {
      ...this.project,
      modifiedAt: Date.now(),
      timeline: {
        ...this.project.timeline,
        tracks: [...this.project.timeline.tracks, track],
      },
    };
    this.project = updated;
    this.render();
    this.callbacks.onProjectChanged(updated);
  }

  private getTimelineDuration(): number {
    if (!this.project) return 30;
    let maxEnd = 0;
    for (const track of this.project.timeline.tracks) {
      for (const clip of track.clips) {
        maxEnd = Math.max(maxEnd, clip.startTime + clip.duration);
      }
    }
    return Math.max(30, maxEnd + 10);
  }

  render(): void {
    this.renderRuler();
    this.renderTracks();
    this.updatePlayheadOnly();
  }

  private renderRuler(): void {
    const duration = this.getTimelineDuration();
    const width = duration * PIXELS_PER_SECOND;
    this.rulerEl.style.width = `${width}px`;
    this.rulerEl.innerHTML = "";

    const step = 5;
    for (let t = 0; t <= duration; t += step) {
      const tick = document.createElement("div");
      tick.className = "timeline-ruler-tick";
      tick.style.left = `${t * PIXELS_PER_SECOND}px`;
      const label = document.createElement("span");
      label.className = "timeline-ruler-tick-label";
      label.textContent = formatTimecode(t, 30).slice(0, 8);
      tick.appendChild(label);
      this.rulerEl.appendChild(tick);
    }
  }

  private renderTracks(): void {
    if (!this.project) {
      this.tracksEl.innerHTML = "";
      return;
    }

    const duration = this.getTimelineDuration();
    const width = duration * PIXELS_PER_SECOND;
    this.tracksEl.innerHTML = "";
    this.tracksEl.style.position = "relative";

    for (const track of this.project.timeline.tracks) {
      const trackEl = document.createElement("div");
      trackEl.className = "timeline-track";

      const header = document.createElement("div");
      header.className = "timeline-track-header";
      const nameEl = document.createElement("div");
      nameEl.className = "timeline-track-name";
      nameEl.textContent = track.name;
      const typeEl = document.createElement("div");
      typeEl.className = "timeline-track-type";
      typeEl.textContent = track.type;
      const toggles = document.createElement("div");
      toggles.className = "timeline-track-toggles";
      toggles.appendChild(
        this.makeToggle("M", track.muted, () => this.toggleTrackFlag(track.id, "muted")),
      );
      toggles.appendChild(
        this.makeToggle("L", track.locked, () => this.toggleTrackFlag(track.id, "locked")),
      );
      header.append(nameEl, typeEl, toggles);

      const addClipBtn = document.createElement("button");
      addClipBtn.className = "timeline-track-toggle timeline-track-add-clip";
      addClipBtn.textContent = "+ clip";
      addClipBtn.title = `Import a media file onto ${track.name}`;
      addClipBtn.addEventListener("click", () => this.callbacks.onAddClipToTrack(track.id));
      header.appendChild(addClipBtn);

      const lane = document.createElement("div");
      lane.className = "timeline-track-lane";
      lane.style.width = `${width}px`;

      for (const clip of track.clips) {
        lane.appendChild(this.renderClip(clip, track));
      }

      trackEl.append(header, lane);
      this.tracksEl.appendChild(trackEl);
    }

    // renderTracks() wipes the DOM on every call including mid-drag —
    // put the playhead back so it isn't missing for a frame.
    this.updatePlayheadOnly();
  }

  private toggleTrackFlag(trackId: string, flag: "muted" | "locked"): void {
    if (!this.project) return;
    const updated: Project = {
      ...this.project,
      modifiedAt: Date.now(),
      timeline: {
        ...this.project.timeline,
        tracks: this.project.timeline.tracks.map((t) =>
          t.id === trackId ? { ...t, [flag]: !t[flag] } : t,
        ),
      },
    };
    this.project = updated;
    this.render();
    this.callbacks.onProjectChanged(updated);
  }

  private makeToggle(label: string, active: boolean, onClick: () => void): HTMLElement {
    const btn = document.createElement("button");
    btn.className = "timeline-track-toggle" + (active ? " active" : "");
    btn.textContent = label;
    btn.title = label === "M" ? "Mute track" : "Lock track";
    btn.addEventListener("click", onClick);
    return btn;
  }

  private renderClip(clip: Clip, track: Track): HTMLElement {
    const el = document.createElement("div");
    el.className = "timeline-clip" + (clip.id === this.selectedClipId ? " selected" : "");
    el.dataset.trackType = track.type;
    el.dataset.clipId = clip.id;
    el.style.left = `${clip.startTime * PIXELS_PER_SECOND}px`;
    el.style.width = `${Math.max(clip.duration, MIN_CLIP_SECONDS) * PIXELS_PER_SECOND}px`;
    el.textContent = clip.mediaId;
    el.title = `${clip.mediaId}\n${clip.startTime.toFixed(2)}s + ${clip.duration.toFixed(2)}s`;

    el.addEventListener("pointerdown", (e) => this.onClipPointerDown(e, clip, track, "move", el));

    const leftHandle = document.createElement("div");
    leftHandle.className = "timeline-clip-handle left";
    leftHandle.addEventListener("pointerdown", (e) => {
      e.stopPropagation();
      this.onClipPointerDown(e, clip, track, "trim-left", el);
    });

    const rightHandle = document.createElement("div");
    rightHandle.className = "timeline-clip-handle right";
    rightHandle.addEventListener("pointerdown", (e) => {
      e.stopPropagation();
      this.onClipPointerDown(e, clip, track, "trim-right", el);
    });

    el.append(leftHandle, rightHandle);
    return el;
  }

  private updatePlayheadOnly(): void {
    const left = this.currentTime * PIXELS_PER_SECOND;

    let playhead = this.tracksEl.querySelector<HTMLElement>(".timeline-playhead");
    if (!playhead) {
      playhead = document.createElement("div");
      playhead.className = "timeline-playhead";
      this.tracksEl.appendChild(playhead);
    }
    playhead.style.left = `${left}px`;
    playhead.style.height = `${this.tracksEl.scrollHeight}px`;

    if (this.timecodeEl) {
      this.timecodeEl.textContent = formatTimecode(this.currentTime, 30);
    }
  }

  private onRulerPointerDown(e: PointerEvent): void {
    const rect = this.rulerEl.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const time = Math.max(0, x / PIXELS_PER_SECOND);
    this.callbacks.onSeek(time);
  }

  private onClipPointerDown(
    e: PointerEvent,
    clip: Clip,
    track: Track,
    mode: DragMode,
    clipEl: HTMLElement,
  ): void {
    if (track.locked) return;
    e.preventDefault();
    this.selectedClipId = clip.id;
    clipEl.classList.add("selected");

    this.drag = {
      mode,
      clipId: clip.id,
      trackId: track.id,
      clipEl,
      pointerStartX: e.clientX,
      startTimeAtDragStart: clip.startTime,
      durationAtDragStart: clip.duration,
      inPointAtDragStart: clip.inPoint,
      outPointAtDragStart: clip.outPoint,
      draftStartTime: clip.startTime,
      draftDuration: clip.duration,
      draftInPoint: clip.inPoint,
      draftOutPoint: clip.outPoint,
    };

    clipEl.classList.add("dragging");
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
      clipEl.classList.remove("dragging");
      this.commitDrag();
    };
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
  }

  private onDragPointerMove(e: PointerEvent): void {
    if (!this.drag || !this.project) return;
    const deltaSeconds = (e.clientX - this.drag.pointerStartX) / PIXELS_PER_SECOND;
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
        PIXELS_PER_SECOND,
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
      this.drag.draftInPoint = Math.max(0, this.drag.inPointAtDragStart + shift);
    } else {
      const rawDuration = this.drag.durationAtDragStart + deltaSeconds;
      this.drag.draftDuration = Math.max(MIN_CLIP_SECONDS, rawDuration);
      this.drag.draftOutPoint =
        this.drag.outPointAtDragStart + (this.drag.draftDuration - this.drag.durationAtDragStart);
    }

    // Cheap live preview: reposition just this element, no full rebuild.
    this.drag.clipEl.style.left = `${this.drag.draftStartTime * PIXELS_PER_SECOND}px`;
    this.drag.clipEl.style.width = `${Math.max(this.drag.draftDuration, MIN_CLIP_SECONDS) * PIXELS_PER_SECOND}px`;
  }

  private commitDrag(): void {
    if (!this.drag || !this.project) {
      this.drag = null;
      return;
    }
    const { clipId, trackId, draftStartTime, draftDuration, draftInPoint, draftOutPoint } = this.drag;
    this.drag = null;

    const updated: Project = {
      ...this.project,
      modifiedAt: Date.now(),
      timeline: {
        ...this.project.timeline,
        tracks: this.project.timeline.tracks.map((t) => {
          if (t.id !== trackId) return t;
          return {
            ...t,
            clips: t.clips.map((c) =>
              c.id === clipId
                ? {
                    ...c,
                    startTime: draftStartTime,
                    duration: draftDuration,
                    inPoint: draftInPoint,
                    outPoint: draftOutPoint,
                  }
                : c,
            ),
          };
        }),
      },
    };

    this.project = updated;
    this.render();
    this.callbacks.onProjectChanged(updated);
  }
}
