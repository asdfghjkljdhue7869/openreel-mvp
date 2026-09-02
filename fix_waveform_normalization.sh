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

old = """    if (sourceDuration <= 0 || peaks.length === 0) return [];
    const startIdx = Math.max(0, Math.floor((inPoint / sourceDuration) * peaks.length));
    const endIdx = Math.min(peaks.length, Math.ceil((outPoint / sourceDuration) * peaks.length));
    const sliceLen = Math.max(1, endIdx - startIdx);
    const barCount = Math.max(1, Math.min(240, Math.floor(widthPx / 2)));
    const bars: number[] = [];
    for (let i = 0; i < barCount; i++) {
      const from = startIdx + Math.floor((i / barCount) * sliceLen);
      const to = Math.max(from + 1, startIdx + Math.floor(((i + 1) / barCount) * sliceLen));
      let peak = 0;
      for (let j = from; j < to && j < endIdx; j++) {
        peak = Math.max(peak, Math.abs(peaks[j] ?? 0));
      }
      bars.push(Math.min(1, peak));
    }
    return bars;
  }"""

new = """    if (sourceDuration <= 0 || peaks.length === 0) return [];
    const startIdx = Math.max(0, Math.floor((inPoint / sourceDuration) * peaks.length));
    const endIdx = Math.min(peaks.length, Math.ceil((outPoint / sourceDuration) * peaks.length));
    const sliceLen = Math.max(1, endIdx - startIdx);
    const barCount = Math.max(1, Math.min(240, Math.floor(widthPx / 2)));
    const bars: number[] = [];
    for (let i = 0; i < barCount; i++) {
      const from = startIdx + Math.floor((i / barCount) * sliceLen);
      const to = Math.max(from + 1, startIdx + Math.floor(((i + 1) / barCount) * sliceLen));
      let peak = 0;
      for (let j = from; j < to && j < endIdx; j++) {
        peak = Math.max(peak, Math.abs(peaks[j] ?? 0));
      }
      bars.push(Math.min(1, peak));
    }
    // Real-world audio rarely hits absolute peak amplitude 1.0 — rendering
    // bars against that fixed scale meant anything short of already-hot
    // audio looked like a flat row of minimum-height dashes. Normalize
    // against this slice's own loudest sample instead, so the waveform
    // always uses the full visual range regardless of source loudness.
    const maxBar = bars.reduce((m, b) => Math.max(m, b), 0);
    if (maxBar > 0.0001) {
      for (let i = 0; i < bars.length; i++) {
        bars[i] = bars[i] / maxBar;
      }
    }
    return bars;
  }"""

if src.count(old) != 1:
    print(f"ERROR: computeWaveformBars anchor found {src.count(old)} time(s), expected exactly 1 — file layout has changed, aborting.", file=sys.stderr)
    sys.exit(1)

src = src.replace(old, new, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(src)

print("Patched computeWaveformBars to normalize bar heights against the clip's own peak.")
PYEOF

if [ "$(grep -c "maxBar" "$FILE")" -lt 2 ]; then
  echo "ERROR: normalization code not found after patch. Check $FILE manually." >&2
  exit 1
fi

echo ""
echo "Patched $FILE successfully:"
echo "  - waveform bars now scale relative to the clip's own loudest sample, not a fixed absolute scale"
echo "  - quieter audio will now show real variation instead of uniform minimum-height dashes"
echo ""
echo "Run your test suite now:"
echo "  npm test"
