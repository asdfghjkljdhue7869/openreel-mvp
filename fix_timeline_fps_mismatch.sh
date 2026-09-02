#!/usr/bin/env bash
set -euo pipefail

FILE="src/timeline-ui.ts"

if [ ! -f "$FILE" ]; then
  echo "ERROR: $FILE not found. Run this from the openreel-mvp repo root." >&2
  exit 1
fi

if grep -q "getProjectFrameRate" "$FILE"; then
  echo "ERROR: getProjectFrameRate already present in $FILE — patch looks already applied, aborting to avoid double-patching." >&2
  exit 1
fi

python3 - "$FILE" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    src = f.read()

class_anchor = "export class TimelineUI {\n  private project: Project | null = null;"
if src.count(class_anchor) != 1:
    print(f"ERROR: class-field anchor found {src.count(class_anchor)} time(s), expected exactly 1 — file layout has changed, aborting.", file=sys.stderr)
    sys.exit(1)

helper = (
    "export class TimelineUI {\n"
    "  private project: Project | null = null;\n"
    "\n"
    "  private getProjectFrameRate(): number {\n"
    "    return this.project?.settings.frameRate ?? 30;\n"
    "  }"
)
src = src.replace(class_anchor, helper, 1)

call_sites = [
    ("formatTimecode(t, 30)", "formatTimecode(t, this.getProjectFrameRate())"),
    ("formatTimecode(this.currentTime, 30)", "formatTimecode(this.currentTime, this.getProjectFrameRate())"),
]
replaced_total = 0
for old, new in call_sites:
    count = src.count(old)
    if count == 0:
        print(f"ERROR: expected call site not found: {old!r} — file layout has changed, aborting.", file=sys.stderr)
        sys.exit(1)
    src = src.replace(old, new)
    replaced_total += count

with open(path, "w", encoding="utf-8") as f:
    f.write(src)

print(f"Replaced class anchor with helper method, and {replaced_total} call site(s) updated.")
PYEOF

DEFCOUNT=$(grep -c "private getProjectFrameRate" "$FILE" || true)
if [ "$DEFCOUNT" -ne 1 ]; then
  echo "ERROR: helper method definition missing after patch (found $DEFCOUNT). Check $FILE manually." >&2
  exit 1
fi

CALLCOUNT=$(grep -c "this.getProjectFrameRate()" "$FILE" || true)
if [ "$CALLCOUNT" -ne 3 ]; then
  echo "ERROR: expected 3 call sites using the helper, found $CALLCOUNT. Check $FILE manually." >&2
  exit 1
fi

LEFTOVER=$(grep -Ec "formatTimecode\([^)]*, 30\)" "$FILE" || true)
if [ "$LEFTOVER" -ne 0 ]; then
  echo "ERROR: $LEFTOVER hardcoded formatTimecode(..., 30) call(s) still remain. Check $FILE manually." >&2
  exit 1
fi

echo ""
echo "Patched $FILE successfully:"
echo "  - added getProjectFrameRate() helper (falls back to 30 only if no project loaded)"
echo "  - ruler tick labels, live playhead timecode, and toolbar timecode now use the real project frame rate"
echo ""
echo "Run your test suite now:"
echo "  npm test"
