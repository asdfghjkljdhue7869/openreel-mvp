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

if grep -q "headerWidthPx" "$TS_FILE"; then
  echo "ERROR: headerWidthPx already present in $TS_FILE — patch looks already applied, aborting to avoid double-patching." >&2
  exit 1
fi

python3 - "$CSS_FILE" "$TS_FILE" <<'PYEOF'
import sys

css_path, ts_path = sys.argv[1], sys.argv[2]

with open(css_path, "r", encoding="utf-8") as f:
    css = f.read()

css_old = """.timeline-ruler {
  position: relative;
  height: 24px;
  border-bottom: 1px solid var(--border);
  cursor: text;
  background: var(--bg-panel-raised);
}"""
css_new = """.timeline-ruler {
  position: relative;
  height: 24px;
  /* Must match .timeline-track-header's width below — every row's lane
     content starts 132px in because the header is a flex sibling before
     it, so the ruler has to start there too or its ticks (and anything
     that treats the ruler as the click/seek coordinate origin) will be
     132px left of the clips they're supposed to line up with. */
  margin-left: 132px;
  border-bottom: 1px solid var(--border);
  cursor: text;
  background: var(--bg-panel-raised);
}"""

if css.count(css_old) != 1:
    print(f"ERROR: .timeline-ruler CSS block found {css.count(css_old)} time(s), expected exactly 1 — aborting.", file=sys.stderr)
    sys.exit(1)
css = css.replace(css_old, css_new, 1)

with open(css_path, "w", encoding="utf-8") as f:
    f.write(css)

with open(ts_path, "r", encoding="utf-8") as f:
    ts = f.read()

ts_old = """  private updatePlayheadOnly(): void {
    const left = this.currentTime * this.pixelsPerSecond;

    let playhead = this.elements.tracks.querySelector<HTMLElement>(".timeline-playhead");
    if (!playhead) {
      playhead = document.createElement("div");
      playhead.className = "timeline-playhead";
      playhead.addEventListener("pointerdown", (e) => this.onPlayheadPointerDown(e));
      this.elements.tracks.appendChild(playhead);
    }
    playhead.style.left = `${left}px`;
    playhead.style.height = `${this.elements.tracks.scrollHeight}px`;"""

ts_new = """  // Must match .timeline-track-header's CSS width (theme-default.css) —
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
    playhead.style.height = `${this.elements.tracks.scrollHeight}px`;"""

if ts.count(ts_old) != 1:
    print(f"ERROR: updatePlayheadOnly anchor found {ts.count(ts_old)} time(s), expected exactly 1 — aborting.", file=sys.stderr)
    sys.exit(1)
ts = ts.replace(ts_old, ts_new, 1)

live_time_old = """    liveTime.style.left = `${left}px`;"""
if ts.count(live_time_old) != 1:
    print(f"ERROR: liveTime left-assignment found {ts.count(live_time_old)} time(s), expected exactly 1 — aborting.", file=sys.stderr)
    sys.exit(1)
ts = ts.replace(live_time_old, """    liveTime.style.left = `${rawLeft}px`;""", 1)

with open(ts_path, "w", encoding="utf-8") as f:
    f.write(ts)

print("Patched .timeline-ruler CSS (margin-left: 132px) and updatePlayheadOnly() in timeline-ui.ts.")
PYEOF

if [ "$(grep -c "margin-left: 132px" "$CSS_FILE")" -ne 1 ]; then
  echo "ERROR: expected 1 margin-left:132px in $CSS_FILE, found $(grep -c "margin-left: 132px" "$CSS_FILE"). Check manually." >&2
  exit 1
fi
if [ "$(grep -c "headerWidthPx" "$TS_FILE")" -ne 2 ]; then
  echo "ERROR: expected 2 references to headerWidthPx (1 field + 1 use) in $TS_FILE, found $(grep -c "headerWidthPx" "$TS_FILE"). Check manually." >&2
  exit 1
fi
if [ "$(grep -c 'liveTime.style.left = `\${rawLeft}px`;' "$TS_FILE")" -ne 1 ]; then
  echo "ERROR: liveTime left-assignment not using rawLeft as expected. Check $TS_FILE manually." >&2
  exit 1
fi

echo ""
echo "Patched successfully:"
echo "  - .timeline-ruler now starts 132px in, matching where lane content actually begins"
echo "  - the playhead line now renders at the same true position as the ruler tick for that time"
echo "  - ruler-based click/seek math (already fixed earlier) is now correct in absolute terms, not just internally consistent"
echo ""
echo "This should be the actual fix for the playhead/ruler-vs-clip misalignment. Test by clicking a clip's visible edge and confirming the playhead lands exactly there."
echo ""
echo "Run your test suite now:"
echo "  npm test"
