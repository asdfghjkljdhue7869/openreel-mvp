#!/usr/bin/env bash
set -euo pipefail

FILE="src/timeline-ui.ts"

if [ ! -f "$FILE" ]; then
  echo "ERROR: $FILE not found. Run this from the openreel-mvp repo root." >&2
  exit 1
fi

python3 - "$FILE" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    src = f.read()

old = """  private onScrubPointerDown(e: PointerEvent): void {
    const rect = this.elements.tracks.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const time = Math.max(0, x / this.pixelsPerSecond);
    this.callbacks.onSeek(time);
  }"""

new = """  private onScrubPointerDown(e: PointerEvent): void {
    // Must match the ruler's own coordinate origin, not the tracks
    // container's — .timeline-tracks includes each row's 132px
    // .timeline-track-header column (position: sticky; left: 0) in its
    // bounding rect, but the ruler sits only above the lane content. Using
    // tracks' rect here added ~132px of unsubtracted offset to every
    // click-to-seek in a track lane, landing the seek noticeably later
    // than where you actually clicked.
    const rect = this.elements.ruler.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const time = Math.max(0, x / this.pixelsPerSecond);
    this.callbacks.onSeek(time);
  }"""

if src.count(old) != 1:
    print(f"ERROR: onScrubPointerDown anchor found {src.count(old)} time(s), expected exactly 1 — file layout has changed, aborting.", file=sys.stderr)
    sys.exit(1)

src = src.replace(old, new, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(src)

print("Patched onScrubPointerDown to use the ruler's bounding rect instead of the tracks container's.")
PYEOF

if [ "$(grep -c "this.elements.tracks.getBoundingClientRect" "$FILE")" -ne 0 ]; then
  echo "ERROR: tracks.getBoundingClientRect() still present — patch did not fully apply. Check $FILE manually." >&2
  exit 1
fi

echo ""
echo "Patched $FILE successfully:"
echo "  - clicking/scrubbing inside a track lane now seeks to the same time you'd get clicking the same x position on the ruler"
echo "  - this was the ~132px offset causing split-at-playhead (and any lane click) to land later than expected"
echo ""
echo "Run your test suite now:"
echo "  npm test"
