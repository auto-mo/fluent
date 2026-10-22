#!/bin/bash
# Install the current build to /Applications/Fluent.app (so it shows in Finder and Launchpad and
# can open at login), quit the running Fluent (matched by exact path, so test copies and other
# processes are left alone) and start the installed copy.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=/Applications/Fluent.app
for BIN in "$APP/Contents/MacOS/Fluent" "$PWD/build/Fluent.app/Contents/MacOS/Fluent"; do
  for pid in $(pgrep -f -x "$BIN" || true); do
    ps -o pid=,command= -p "$pid"
    kill "$pid"
  done
done
sleep 1
rm -rf "$APP"
ditto build/Fluent.app "$APP"
codesign --verify --strict "$APP"
open "$APP"
