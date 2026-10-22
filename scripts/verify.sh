#!/bin/bash
# Launch the built app in its diagnostic modes and print what it reports.
# Writes build/permissions.json and build/window.png (the setup window as drawn by the app).
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/Fluent.app"
rm -f build/permissions.json build/setup.png build/window.png

open -n -W "$APP" --args --report-permissions "$PWD/build/permissions.json"
open -n -W "$APP" --args --capture-window "$PWD/build/window.png"

cat build/permissions.json
echo
ls -l build/window.png
