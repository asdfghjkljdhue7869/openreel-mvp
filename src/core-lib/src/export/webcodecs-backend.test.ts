import { describe, expect, it, vi } from "vitest";
import { WebCodecsBackend } from "./webcodecs-backend";

class MockImageBitmap {
  closed = false;
  close = vi.fn(() => {
    this.closed = true;
  });
}

function makeBackendWithVideoSource(addImpl: (sample: unknown) => Promise<void>) {
  const closeCalls: string[] = [];

  class MockVideoSample {
    closed = false;
    constructor(
      public frame: unknown,
      public opts: unknown,
    ) {}
    close() {
      this.closed = true;
      closeCalls.push("videoSample");
    }
  }

  const videoSource = { add: vi.fn(addImpl) };

  const mediabunny = {
    VideoSample: MockVideoSample,
  } as unknown as typeof import("mediabunny");

  const backend = new WebCodecsBackend(mediabunny);
  // videoSource is private; start() would need a full Output/writableStream
  // setup we don't need here, so we reach in directly for this unit test.
  (backend as unknown as { videoSource: typeof videoSource }).videoSource =
    videoSource;

  return { backend, videoSource, closeCalls };
}

describe("WebCodecsBackend.addVideoFrame", () => {
  it("closes the VideoSample and ImageBitmap on success", async () => {
    const { backend } = makeBackendWithVideoSource(async () => {});
    const frame = new MockImageBitmap();

    await backend.addVideoFrame(frame as unknown as ImageBitmap, 0, 1 / 30);

    expect(frame.closed).toBe(true);
  });

  it("still closes the VideoSample and ImageBitmap when the encoder throws mid-add (e.g. a hardware encoder failure)", async () => {
    const { backend } = makeBackendWithVideoSource(async () => {
      throw new Error("OperationError: Encoding error.");
    });
    const frame = new MockImageBitmap();

    await expect(
      backend.addVideoFrame(frame as unknown as ImageBitmap, 0, 1 / 30),
    ).rejects.toThrow("Encoding error");

    // This is the exact bug: before the fix, a thrown add() left both the
    // VideoSample and the ImageBitmap it wraps unclosed, which is what
    // produces the "A VideoSample was garbage collected without first
    // being closed" warning during a real hardware-encode-failure retry.
    expect(frame.closed).toBe(true);
  });
});
