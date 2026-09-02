#!/usr/bin/env bash
set -euo pipefail

FILE="src/timeline-ui.ts"

if [ ! -f "$FILE" ]; then
  echo "ERROR: $FILE not found. Run this from the openreel-mvp repo root." >&2
  exit 1
fi

if ! grep -q "logSplitResult" "$FILE"; then
  echo "ERROR: logSplitResult not found in $FILE — run add_split_logging.sh first, this patch builds on it." >&2
  exit 1
fi

if grep -q "logTrackState" "$FILE"; then
  echo "ERROR: logTrackState already present in $FILE — patch looks already applied, aborting to avoid double-patching." >&2
  exit 1
fi

python3 - "$FILE" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    src = f.read()

anchor_old = "  private logSplitResult(trackId: string, requestedTime: number): void {"
if src.count(anchor_old) != 1:
    print(f"ERROR: logSplitResult method anchor found {src.count(anchor_old)} time(s), expected exactly 1 — aborting.", file=sys.stderr)
    sys.exit(1)

helper = """  // Same idea as logSplitResult but reusable after any track-mutating
  // action (move, trim) — a move that only repositions one piece of a
  // previously-split clip can silently open a gap or overlap the next
  // clip, which looks "weird" in the UI with no obvious cause otherwise.
  private logTrackState(trackId: string, label: string): void {
    if (!this.project) return;
    const track = this.project.timeline.tracks.find((t) => t.id === trackId);
    if (!track) return;
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
      `${label} -> track ${trackId.slice(0, 8)} now has ${clips.length} clip(s): ${parts.join(" | ")}${anomalies}`,
    );
  }

"""
src = src.replace(anchor_old, helper + anchor_old, 1)

trim_group_old = """      this.log(
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
    }"""

trim_group_new = """      this.log(
        `Trimmed clip ${shortId} (${drag.mode}): start ${fmt(drag.startTimeAtDragStart)}s->${fmt(drag.draftStartTime)}s, duration ${fmt(drag.durationAtDragStart)}s->${fmt(drag.draftDuration)}s`,
      );
      this.afterMutation();
      this.logTrackState(drag.trackId, "Trim result");
    } else if (startChanged) {
      const ok = await this.runAction(
        makeAction("clip/move", { clipId: drag.clipId, startTime: drag.draftStartTime }),
      );
      if (ok) {
        this.log(`Moved clip ${shortId}: start ${fmt(drag.startTimeAtDragStart)}s->${fmt(drag.draftStartTime)}s`);
        this.logTrackState(drag.trackId, "Move result");
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
        this.logTrackState(drag.trackId, "Trim result");
      }
    }"""

if src.count(trim_group_old) != 1:
    print(f"ERROR: move/trim commit block anchor found {src.count(trim_group_old)} time(s), expected exactly 1 — aborting.", file=sys.stderr)
    sys.exit(1)
src = src.replace(trim_group_old, trim_group_new, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(src)

print("Added logTrackState() helper and wired it into all 3 move/trim commit branches.")
PYEOF

DEFCOUNT=$(grep -c "private logTrackState" "$FILE" || true)
if [ "$DEFCOUNT" -ne 1 ]; then
  echo "ERROR: expected 1 logTrackState definition, found $DEFCOUNT. Check $FILE manually." >&2
  exit 1
fi

CALLCOUNT=$(grep -c "this.logTrackState(" "$FILE" || true)
if [ "$CALLCOUNT" -ne 3 ]; then
  echo "ERROR: expected 3 logTrackState call sites (trim-group, move, trim), found $CALLCOUNT. Check $FILE manually." >&2
  exit 1
fi

echo ""
echo "Patched $FILE successfully:"
echo "  - added logTrackState() — same before/after clip dump as split logging, now covers move and trim too"
echo "  - a move or trim that opens a gap or creates an overlap will now show up explicitly in the log"
echo ""
echo "Run your test suite now:"
echo "  npm test"
