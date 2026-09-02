#!/usr/bin/env bash
set -euo pipefail

FILE="src/timeline-ui.ts"

if [ ! -f "$FILE" ]; then
  echo "ERROR: $FILE not found. Run this from the openreel-mvp repo root." >&2
  exit 1
fi

if grep -q "logSplitResult" "$FILE"; then
  echo "ERROR: logSplitResult already present in $FILE — patch looks already applied, aborting to avoid double-patching." >&2
  exit 1
fi

python3 - "$FILE" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    src = f.read()

anchor_old = """  private log(message: string): void {
    this.callbacks.onLog?.(`[timeline] ${message}`);
  }
"""
anchor_new = """  private log(message: string): void {
    this.callbacks.onLog?.(`[timeline] ${message}`);
  }

  // Split (clip/split in action-executor.ts) trusts whatever `time` it's
  // given with no bounds-checking of its own — if that time is ever even
  // slightly outside the target clip's [startTime, startTime+duration)
  // range when the action actually runs, it silently produces a
  // zero/negative-duration clip or an overlapping pair rather than
  // erroring. Log the full resulting track state after every split so a
  // "weird" split has concrete before/after numbers instead of a guess.
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
"""

if src.count(anchor_old) != 1:
    print(f"ERROR: log() method anchor found {src.count(anchor_old)} time(s), expected exactly 1 — aborting.", file=sys.stderr)
    sys.exit(1)
src = src.replace(anchor_old, anchor_new, 1)

call_site_1_old = """    splitBtn.addEventListener("click", () => {
      const t = this.currentTime;
      void this.runAction(makeAction("clip/split", { clipId: clip.id, time: t })).then((ok) => {
        if (ok) this.log(`Split clip ${clip.id.slice(0, 8)} at ${t.toFixed(2)}s`);
      });
    });"""
call_site_1_new = """    splitBtn.addEventListener("click", () => {
      const t = this.currentTime;
      void this.runAction(makeAction("clip/split", { clipId: clip.id, time: t })).then((ok) => {
        if (ok) this.logSplitResult(clip.trackId, t);
      });
    });"""

if src.count(call_site_1_old) != 1:
    print(f"ERROR: split-button call site found {src.count(call_site_1_old)} time(s), expected exactly 1 — aborting.", file=sys.stderr)
    sys.exit(1)
src = src.replace(call_site_1_old, call_site_1_new, 1)

call_site_2_old = """            const t = this.currentTime;
            void this.runAction(makeAction("clip/split", { clipId: clip.id, time: t })).then((ok) => {
              if (ok) this.log(`Split clip ${clip.id.slice(0, 8)} at ${t.toFixed(2)}s`);
            });"""
call_site_2_new = """            const t = this.currentTime;
            void this.runAction(makeAction("clip/split", { clipId: clip.id, time: t })).then((ok) => {
              if (ok) this.logSplitResult(clip.trackId, t);
            });"""

if src.count(call_site_2_old) != 1:
    print(f"ERROR: split-shortcut call site found {src.count(call_site_2_old)} time(s), expected exactly 1 — aborting.", file=sys.stderr)
    sys.exit(1)
src = src.replace(call_site_2_old, call_site_2_new, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(src)

print("Added logSplitResult() helper and wired it into both split call sites (toolbar button + S shortcut).")
PYEOF

if [ "$(grep -c "logSplitResult" "$FILE")" -ne 3 ]; then
  echo "ERROR: expected 3 references to logSplitResult (1 definition + 2 call sites), found $(grep -c "logSplitResult" "$FILE"). Check $FILE manually." >&2
  exit 1
fi

echo ""
echo "Patched $FILE successfully:"
echo "  - added logSplitResult() — logs full before/after clip state after every split"
echo "  - flags ZERO/NEGATIVE-DURATION clips and GAP/OVERLAP between adjacent clips automatically"
echo "  - wired into both the 'Split at playhead' button and the S keyboard shortcut"
echo ""
echo "Next time the split looks weird, reproduce it and paste the resulting [timeline] log line — it'll show exact start/duration/in/out for every clip on that track plus any anomaly flags."
echo ""
echo "Run your test suite now:"
echo "  npm test"
