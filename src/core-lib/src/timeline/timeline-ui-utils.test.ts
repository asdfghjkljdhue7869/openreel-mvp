import { describe, expect, it } from "vitest";
import type { Track } from "../types";
import {
  calculateSnap,
  formatTimecode,
  getTrackDragAutoScrollDelta,
  DEFAULT_SNAP_SETTINGS,
} from "./timeline-ui-utils";

function makeTrack(clips: { id: string; startTime: number; duration: number }[]): Track {
  return {
    id: "track-1",
    type: "video",
    name: "V1",
    clips: clips.map((c) => ({
      id: c.id,
      mediaId: "media-1",
      trackId: "track-1",
      startTime: c.startTime,
      duration: c.duration,
      inPoint: 0,
      outPoint: c.duration,
      effects: [],
      audioEffects: [],
      transform: {
        position: { x: 0, y: 0 },
        scale: { x: 1, y: 1 },
        rotation: 0,
        anchor: { x: 0.5, y: 0.5 },
        opacity: 1,
      },
      volume: 1,
      keyframes: [],
    })),
    transitions: [],
    locked: false,
    hidden: false,
    muted: false,
    solo: false,
  };
}

describe("calculateSnap", () => {
  it("snaps a dragged clip's start to a neighboring clip's end within threshold", () => {
    const tracks = [makeTrack([{ id: "clip-a", startTime: 0, duration: 5 }])];
    const result = calculateSnap(
      5.05,
      "clip-b",
      tracks,
      /* playheadPosition */ 20,
      DEFAULT_SNAP_SETTINGS,
      /* pixelsPerSecond */ 60,
    );
    expect(result.snapped).toBe(true);
    expect(result.time).toBe(5);
  });

  it("does not snap when the nearest point is outside the pixel threshold", () => {
    const tracks = [makeTrack([{ id: "clip-a", startTime: 0, duration: 5 }])];
    const result = calculateSnap(
      6,
      "clip-b",
      tracks,
      20,
      DEFAULT_SNAP_SETTINGS,
      60,
    );
    expect(result.snapped).toBe(false);
    expect(result.time).toBe(6);
  });

  it("snaps to the playhead position", () => {
    const tracks = [makeTrack([])];
    const result = calculateSnap(
      10.05,
      "clip-a",
      tracks,
      10,
      DEFAULT_SNAP_SETTINGS,
      60,
    );
    expect(result.snapped).toBe(true);
    expect(result.time).toBe(10);
  });

  it("is a no-op when snapping is disabled", () => {
    const tracks = [makeTrack([{ id: "clip-a", startTime: 0, duration: 5 }])];
    const result = calculateSnap(
      5.05,
      "clip-b",
      tracks,
      20,
      { ...DEFAULT_SNAP_SETTINGS, enabled: false },
      60,
    );
    expect(result.snapped).toBe(false);
    expect(result.time).toBe(5.05);
  });

  it("never returns a negative snapped time", () => {
    const tracks = [makeTrack([{ id: "clip-a", startTime: 0, duration: 5 }])];
    const result = calculateSnap(
      -0.02,
      "clip-b",
      tracks,
      20,
      DEFAULT_SNAP_SETTINGS,
      60,
    );
    expect(result.time).toBeGreaterThanOrEqual(0);
  });
});

describe("formatTimecode", () => {
  it("formats hours:minutes:seconds:frames", () => {
    expect(formatTimecode(3661.5, 30)).toBe("01:01:01:15");
  });

  it("handles zero", () => {
    expect(formatTimecode(0)).toBe("00:00:00:00");
  });

  it("falls back to 00:00:00:00 for invalid input", () => {
    expect(formatTimecode(NaN)).toBe("00:00:00:00");
    expect(formatTimecode(-5)).toBe("00:00:00:00");
    expect(formatTimecode(Infinity)).toBe("00:00:00:00");
  });
});

describe("getTrackDragAutoScrollDelta", () => {
  it("returns 0 when the pointer is away from either edge", () => {
    const delta = getTrackDragAutoScrollDelta(500, 0, 1000, 50, 500);
    expect(delta).toBe(0);
  });

  it("returns a negative delta approaching the start edge, scaled by depth", () => {
    const delta = getTrackDragAutoScrollDelta(10, 0, 1000, 50, 500);
    expect(delta).toBeLessThan(0);
  });

  it("returns a positive delta approaching the end edge", () => {
    const delta = getTrackDragAutoScrollDelta(990, 0, 1000, 50, 500);
    expect(delta).toBeGreaterThan(0);
  });

  it("does not scroll past the start when already at 0", () => {
    const delta = getTrackDragAutoScrollDelta(10, 0, 1000, 0, 500);
    expect(delta).toBe(0);
  });

  it("does not scroll past the end when already at max", () => {
    const delta = getTrackDragAutoScrollDelta(990, 0, 1000, 500, 500);
    expect(delta).toBe(0);
  });
});
