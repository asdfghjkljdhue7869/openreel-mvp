#!/usr/bin/env bash
set -euo pipefail

CSS_FILE="src/theme-default.css"
TS_FILE="src/timeline-ui.ts"

if [ ! -f "$CSS_FILE" ]; then
  echo "ERROR: $CSS_FILE not found. Run this from the openreel-mvp repo root." >&2
  exit 1
fi
if [ ! -f "$TS_FILE" ]; then
  echo "ERROR: $TS_FILE not found. Run this from the openreel-mvp repo root." >&2
  exit 1
fi

if grep -q "timeline-ruler-hover-time" "$TS_FILE"; then
  echo "ERROR: hover-time feature already present in $TS_FILE — patch looks already applied, aborting to avoid double-patching." >&2
  exit 1
fi
if ! grep -q "getProjectFrameRate" "$TS_FILE"; then
  echo "ERROR: getProjectFrameRate not found in $TS_FILE — run fix_timeline_fps_mismatch.sh first, this patch depends on it." >&2
  exit 1
fi

python3 - "$CSS_FILE" "$TS_FILE" <<'PYEOF'
import sys

css_path, ts_path = sys.argv[1], sys.argv[2]

with open(css_path, "r", encoding="utf-8") as f:
    css = f.read()

css_anchor = """.timeline-ruler-live-time {
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
}"""

if css.count(css_anchor) != 1:
    print(f"ERROR: .timeline-ruler-live-time CSS anchor found {css.count(css_anchor)} time(s), expected exactly 1 — aborting.", file=sys.stderr)
    sys.exit(1)

css_addition = css_anchor + """

.timeline-ruler-hover-time {
  position: absolute;
  top: 1px;
  transform: translateX(2px);
  background: var(--bg-panel-raised);
  border: 1px solid var(--border);
  color: var(--text-secondary);
  font-family: var(--font-mono);
  font-size: 0.6rem;
  line-height: 1.3;
  padding: 0 4px;
  border-radius: 2px;
  white-space: nowrap;
  pointer-events: none;
  z-index: 3;
  display: none;
}"""

css = css.replace(css_anchor, css_addition, 1)

with open(css_path, "w", encoding="utf-8") as f:
    f.write(css)

with open(ts_path, "r", encoding="utf-8") as f:
    ts = f.read()

ctor_old = """    this.elements.ruler.addEventListener("pointerdown", (e) => this.onRulerPointerDown(e));"""
ctor_new = """    this.elements.ruler.addEventListener("pointerdown", (e) => this.onRulerPointerDown(e));
    this.elements.ruler.addEventListener("pointermove", (e) => this.onTimelineHover(e));
    this.elements.ruler.addEventListener("pointerleave", () => this.hideHoverTime());
    this.elements.tracks.addEventListener("pointermove", (e) => this.onTimelineHover(e));
    this.elements.tracks.addEventListener("pointerleave", () => this.hideHoverTime());"""

if ts.count(ctor_old) != 1:
    print(f"ERROR: constructor listener anchor found {ts.count(ctor_old)} time(s), expected exactly 1 — aborting.", file=sys.stderr)
    sys.exit(1)
ts = ts.replace(ctor_old, ctor_new, 1)

method_anchor = """  private onRulerPointerDown(e: PointerEvent): void {"""
if ts.count(method_anchor) != 1:
    print(f"ERROR: onRulerPointerDown anchor found {ts.count(method_anchor)} time(s), expected exactly 1 — aborting.", file=sys.stderr)
    sys.exit(1)

new_methods = """  // Shows the time under the mouse as it moves over the ruler or a track
  // lane, even without clicking — separate from the (red) live playhead
  // time label, which only reflects where playback/the playhead actually
  // is. Uses the ruler's own rect as the coordinate origin, same as every
  // click-to-seek handler, so this always agrees with where a click here
  // would actually land.
  private onTimelineHover(e: PointerEvent): void {
    const rect = this.elements.ruler.getBoundingClientRect();
    const x = e.clientX - rect.left;
    if (x < 0) {
      this.hideHoverTime();
      return;
    }
    const time = x / this.pixelsPerSecond;
    let label = this.elements.ruler.querySelector<HTMLElement>(".timeline-ruler-hover-time");
    if (!label) {
      label = document.createElement("div");
      label.className = "timeline-ruler-hover-time";
      this.elements.ruler.appendChild(label);
    }
    label.style.left = `${x}px`;
    label.style.display = "block";
    label.textContent = formatTimecode(time, this.getProjectFrameRate()).slice(0, 8);
  }

  private hideHoverTime(): void {
    const label = this.elements.ruler.querySelector<HTMLElement>(".timeline-ruler-hover-time");
    if (label) label.style.display = "none";
  }

  """ + method_anchor

ts = ts.replace(method_anchor, new_methods, 1)

with open(ts_path, "w", encoding="utf-8") as f:
    f.write(ts)

print("Added hover-time indicator: CSS class plus onTimelineHover/hideHoverTime wired into the ruler and track lanes.")
PYEOF

if [ "$(grep -c "timeline-ruler-hover-time" "$TS_FILE")" -lt 3 ]; then
  echo "ERROR: expected hover-time references in $TS_FILE not all found. Check manually." >&2
  exit 1
fi
if [ "$(grep -c "timeline-ruler-hover-time" "$CSS_FILE")" -ne 1 ]; then
  echo "ERROR: expected 1 CSS rule for .timeline-ruler-hover-time, found $(grep -c "timeline-ruler-hover-time" "$CSS_FILE"). Check manually." >&2
  exit 1
fi

echo ""
echo "Patched successfully:"
echo "  - hovering anywhere over the ruler or a track lane now shows the time at that x position"
echo "  - shown in a muted label distinct from the red live-playhead time, so they're never confused"
echo ""
echo "Run your test suite now:"
echo "  npm test"
