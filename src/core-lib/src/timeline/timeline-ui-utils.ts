import type { Track } from "../types";

// Ported from Augani/openreel-video (apps/web/src/components/editor/timeline/utils.ts
// and track-drag-auto-scroll.ts) — the upstream project this core-lib was extracted
// from. These two functions have zero React/Tailwind dependency in the original and
// are unchanged here beyond removing the (already-unused-here) icon imports.

export interface SnapPoint {
  time: number;
  type: "clip-start" | "clip-end" | "playhead" | "marker" | "grid";
}

export interface TimelineUISnapResult {
  time: number;
  snapped: boolean;
  snapPoint?: SnapPoint;
}

export interface SnapSettings {
  enabled: boolean;
  snapToClips: boolean;
  snapToPlayhead: boolean;
  snapToGrid: boolean;
  gridSize: number;
  snapThreshold: number;
}

export const DEFAULT_SNAP_SETTINGS: SnapSettings = {
  enabled: true,
  snapToClips: true,
  snapToPlayhead: true,
  snapToGrid: false,
  gridSize: 1,
  snapThreshold: 8,
};

export const calculateSnap = (
  rawTime: number,
  clipId: string,
  tracks: Track[],
  playheadPosition: number,
  snapSettings: SnapSettings,
  pixelsPerSecond: number,
  clipDuration?: number,
): TimelineUISnapResult => {
  if (!snapSettings.enabled) {
    return { time: rawTime, snapped: false };
  }

  const thresholdSeconds = snapSettings.snapThreshold / pixelsPerSecond;
  const snapPoints: SnapPoint[] = [];

  if (snapSettings.snapToClips) {
    for (const track of tracks) {
      for (const clip of track.clips) {
        if (clip.id === clipId) continue;
        snapPoints.push({ time: clip.startTime, type: "clip-start" });
        snapPoints.push({
          time: clip.startTime + clip.duration,
          type: "clip-end",
        });
      }
    }
  }

  if (snapSettings.snapToPlayhead) {
    snapPoints.push({ time: playheadPosition, type: "playhead" });
  }

  if (snapSettings.snapToGrid) {
    const nearestGrid =
      Math.round(rawTime / snapSettings.gridSize) * snapSettings.gridSize;
    snapPoints.push({ time: nearestGrid, type: "grid" });
    if (clipDuration) {
      const endTime = rawTime + clipDuration;
      const nearestEndGrid =
        Math.round(endTime / snapSettings.gridSize) * snapSettings.gridSize;
      snapPoints.push({ time: nearestEndGrid, type: "grid" });
    }
  }

  const priorityOrder: Record<string, number> = {
    "clip-start": 0,
    "clip-end": 0,
    playhead: 1,
    grid: 2,
  };

  let closestPoint: SnapPoint | undefined;
  let closestDistance = Infinity;
  let closestPriority = Infinity;
  let snapFromEnd = false;

  for (const point of snapPoints) {
    const pointPriority = priorityOrder[point.type] ?? 2;

    const startDistance = Math.abs(point.time - rawTime);
    if (startDistance < thresholdSeconds) {
      const isBetter =
        pointPriority < closestPriority ||
        (pointPriority === closestPriority && startDistance < closestDistance);
      if (isBetter) {
        closestDistance = startDistance;
        closestPriority = pointPriority;
        closestPoint = point;
        snapFromEnd = false;
      }
    }

    if (clipDuration) {
      const clipEndTime = rawTime + clipDuration;
      const endDistance = Math.abs(point.time - clipEndTime);
      if (endDistance < thresholdSeconds) {
        const isBetter =
          pointPriority < closestPriority ||
          (pointPriority === closestPriority && endDistance < closestDistance);
        if (isBetter) {
          closestDistance = endDistance;
          closestPriority = pointPriority;
          closestPoint = point;
          snapFromEnd = true;
        }
      }
    }
  }

  if (closestPoint) {
    const snappedTime = snapFromEnd
      ? closestPoint.time - (clipDuration ?? 0)
      : closestPoint.time;
    return {
      time: Math.max(0, snappedTime),
      snapped: true,
      snapPoint: { ...closestPoint, time: closestPoint.time },
    };
  }

  return { time: rawTime, snapped: false };
};

export const formatTimecode = (
  timeInSeconds: number,
  frameRate: number = 30,
): string => {
  if (!isFinite(timeInSeconds) || isNaN(timeInSeconds) || timeInSeconds < 0) {
    return "00:00:00:00";
  }
  const hours = Math.floor(timeInSeconds / 3600);
  const minutes = Math.floor((timeInSeconds % 3600) / 60);
  const seconds = Math.floor(timeInSeconds % 60);
  const frames = Math.floor((timeInSeconds % 1) * frameRate);
  return `${hours.toString().padStart(2, "0")}:${minutes
    .toString()
    .padStart(2, "0")}:${seconds.toString().padStart(2, "0")}:${frames
    .toString()
    .padStart(2, "0")}`;
};

const DEFAULT_EDGE_ZONE = 72;
const DEFAULT_MIN_SPEED = 2;
const DEFAULT_MAX_SPEED = 18;

interface TrackDragAutoScrollOptions {
  edgeZone?: number;
  minSpeed?: number;
  maxSpeed?: number;
}

/**
 * Returns the horizontal (adapted from the original's vertical track-list
 * reordering) scroll delta for one animation frame while dragging a clip
 * near the edge of the timeline's visible area. Speed ramps up as the
 * pointer approaches the edge.
 */
export function getTrackDragAutoScrollDelta(
  pointerPos: number,
  viewportStart: number,
  viewportEnd: number,
  scrollPos: number,
  maxScrollPos: number,
  options: TrackDragAutoScrollOptions = {},
): number {
  const edgeZone = options.edgeZone ?? DEFAULT_EDGE_ZONE;
  const minSpeed = options.minSpeed ?? DEFAULT_MIN_SPEED;
  const maxSpeed = options.maxSpeed ?? DEFAULT_MAX_SPEED;

  if (edgeZone <= 0 || viewportEnd <= viewportStart) return 0;

  const speedForDepth = (depth: number) => {
    const progress = Math.max(0, Math.min(1, depth / edgeZone));
    return minSpeed + (maxSpeed - minSpeed) * progress * progress;
  };

  const startBoundary = viewportStart + edgeZone;
  if (pointerPos < startBoundary && scrollPos > 0) {
    return -speedForDepth(startBoundary - pointerPos);
  }

  const endBoundary = viewportEnd - edgeZone;
  if (pointerPos > endBoundary && scrollPos < maxScrollPos) {
    return speedForDepth(pointerPos - endBoundary);
  }

  return 0;
}
