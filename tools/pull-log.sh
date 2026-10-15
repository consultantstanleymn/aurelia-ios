#!/usr/bin/env bash
# Pulls Aurelia's diagnostic log off the phone and prints it.
#
#   bash tools/pull-log.sh              # last 40 lines
#   bash tools/pull-log.sh 200          # last 200 lines
#   bash tools/pull-log.sh all          # the whole file
#
# The app cannot be started from this machine - xtool launch fails with
# DebugserverClient.Error.unknown before the process exists - so it only runs when the icon is
# tapped. This file is the one place anything the app did can be seen: no debugger, no
# screenshots, and NSLog goes nowhere on this device.
#
# The bundle id is NOT the one in xtool.yml. Free-account signing prefixes it on the device, and
# ifuse fails with InstallationLookupFailed if given the unprefixed one.
set -euo pipefail

UDID="${AURELIA_UDID:-$(idevice_id -l | head -1)}"
BUNDLE="XTL-V63Z8847B5.ch.stanley.aurelia"
MOUNT="${TMPDIR:-/tmp}/aurelia-cont"
LINES="${1:-40}"

if [ -z "$UDID" ]; then
  echo "no device. Plug it in and unlock it, or set AURELIA_UDID." >&2
  exit 1
fi

# A mount left behind by an interrupted run is an I/O error rather than an empty directory, and
# ifuse then refuses to mount over it.
fusermount -u "$MOUNT" 2>/dev/null || true
mkdir -p "$MOUNT"

cleanup() { fusermount -u "$MOUNT" 2>/dev/null || true; }
trap cleanup EXIT

if ! ifuse -u "$UDID" --documents "$BUNDLE" "$MOUNT" 2>/dev/null; then
  echo "could not mount $BUNDLE's Documents on $UDID." >&2
  echo "  if this says InstallationLookupFailed, the app is not installed, or the" >&2
  echo "  XTL- prefix above does not match this signing account." >&2
  exit 1
fi

LOG="$MOUNT/aurelia.log"
if [ ! -f "$LOG" ]; then
  echo "no aurelia.log yet — the app has not been opened since this build was installed."
  echo "(mount: $MOUNT, contents: $(ls -A "$MOUNT" | tr '\n' ' '))"
  exit 0
fi

echo "aurelia.log — $(wc -l < "$LOG") lines, $(du -h "$LOG" | cut -f1)"
echo
case "$LINES" in
  all) cat "$LOG" ;;
  *)    tail -n "$LINES" "$LOG" ;;
esac