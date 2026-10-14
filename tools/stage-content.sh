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

echo "staged into $DEST"
