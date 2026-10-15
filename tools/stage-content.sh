#!/usr/bin/env bash
# Copies the three curricula out of the study-mentor checkout and into the app bundle.
#
# They are a build input, not source: the app is a rewrite of that tutor, and the curricula are
# separate repositories that the Python version clones into ~/study-mentor/content. Copying them
# in here rather than committing them keeps this repo small and keeps a single source of truth for
# the material itself.
#
#   bash tools/stage-content.sh [path-to-study-mentor]
#
# Default source is ~/study-mentor, which is where the Python tutor keeps its clones.
set -euo pipefail

SOURCE="${1:-$HOME/study-mentor}"
DEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Sources/StudyBuddy/Resources/Content"

for track in aws-sa-pro-curriculum lsat-170-curriculum quant-checklist; do
  from="$SOURCE/content/$track"
  if [ ! -d "$from" ]; then
    echo "missing: $from" >&2
    echo "  the Python tutor clones its curricula into study-mentor/content; see its README." >&2
    exit 1
  fi
  rm -rf "${DEST:?}/$track"
  cp -r "$from" "$DEST/$track"
  printf '  %-26s %s\n' "$track" "$(du -sh "$DEST/$track" | cut -f1)"
done

# The quant checklist ships its 24 weeks as a JavaScript object literal, not JSON, and there is no
# JavaScript engine on the phone to evaluate it. It is converted here, at staging time, on the
# machine that has node — the same trick the Python tutor uses in content.py. The app then reads a
# plain JSON file like every other track.
QUANT="$DEST/quant-checklist/checklist-data.js"
if [ -f "$QUANT" ]; then
  node -e '
    const fs = require("fs");
    eval(fs.readFileSync(process.argv[1], "utf8") + ";globalThis.__M = MONTHS;");
    const months = globalThis.__M;
    const weeks = [];
    for (const m of months) {
      for (const w of m.weeks || []) {
        const tasks = [];
        for (const c of w.categories || []) {
          for (const t of c.tasks || []) {
            tasks.push({
              category: c.label || "",
              text: t.text || "",
              note: t.note || "",
              steps: (t.steps || []).map(s => typeof s === "string" ? s : (s.text || "")),
              links: (t.links || []).map(l => `${l.title || ""}${l.desc ? " (" + l.desc + ")" : ""}`)
            });
          }
        }
        weeks.push({
          week: w.week, title: w.title || "", date: w.date || "",
          month: m.name || "", period: m.period || "", tasks: tasks
        });
      }
    }
    fs.writeFileSync(process.argv[2], JSON.stringify({ weeks: weeks }, null, 1));
    console.log("    quant weeks: " + weeks.length);
  ' "$QUANT" "$DEST/quant-checklist/weeks.json"
fi

echo "staged into $DEST"
