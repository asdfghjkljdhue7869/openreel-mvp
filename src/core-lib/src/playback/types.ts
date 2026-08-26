import type { RenderedFrame } from "../video/types";
import type { RenderedAudio } from "../audio/types";

export type PlaybackState = "stopped" | "playing" | "paused" | "seeking";

export interface PlaybackConfig {
  readonly frameRate: number;
  readonly audioBufferSize: number;
  readonly frameBufferAhead: number;
  readonly audioLookahead: number;
  readonly frameRenderTimeout: number;
  readonly enableAudio: boolean;
  readonly enableVideo: boolean;
  /**
   * Caps the long edge of the frame rendered for realtime preview playback.
   * Sources at or below this resolution render at native size, unchanged.
   * Sources above it are rendered at a proportionally scaled-down
   * resolution instead — decode and compositing cost scale with pixel
   * count, so a 4K/8K source previewed at full resolution does roughly
   * 4x-16x more work per frame than necessary for an on-screen player that
   * can't display more detail than its own pixel size anyway. Export is
   * completely unaffected by this — it always renders at the project's
   * actual output resolution. Set to undefined to disable capping entirely
   * and always render preview at native resolution.
   */
  readonly previewMaxDimension?: number;
}

export const DEFAULT_PLAYBACK_CONFIG: PlaybackConfig = {
  frameRate: 30,
  audioBufferSize: 4096,
  frameBufferAhead: 5,
  audioLookahead: 0.1,
  frameRenderTimeout: 100, // 100ms as per requirement 6.3
  enableAudio: true,
  enableVideo: true,
  previewMaxDimension: 1280,
};

export type PlaybackEventType =
  | "play"
  | "pause"
  | "stop"
  | "seek"
  | "timeupdate"
  | "ended"
  | "error"
  | "statechange"
  | "framerendered"
  | "bufferunderrun";

export interface PlaybackEvent {
  readonly type: PlaybackEventType;
  readonly time: number;
  readonly state: PlaybackState;
  readonly error?: Error;
  readonly frame?: RenderedFrame;
}

export type PlaybackEventListener = (event: PlaybackEvent) => void;

export interface ScrubRequest {
  readonly time: number;
  readonly requestedAt: number;
  readonly priority: number;
}

export interface PlaybackStats {
  readonly currentTime: number;
  readonly duration: number;
  readonly state: PlaybackState;
  readonly fps: number;
  readonly droppedFrames: number;
  readonly audioBufferHealth: number;
  readonly videoBufferHealth: number;
  readonly avgFrameRenderTime: number;
}

export interface FrameRenderResult {
  readonly frame: RenderedFrame | null;
  readonly renderTime: number;
  readonly fromCache: boolean;
  readonly timedOut: boolean;
}

export interface AudioRenderResult {
  readonly audio: RenderedAudio | null;
  readonly renderTime: number;
  readonly success: boolean;
}
