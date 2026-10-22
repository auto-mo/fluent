#!/bin/bash
# Build Fluent and copy the signed app to build/Fluent.app.
# Usage: scripts/build.sh            (Debug)
#        scripts/build.sh Release
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"
# An active Anaconda environment exports LD, CC and friends; Xcode would then link with
# Anaconda's ld and fail ("unknown option: -Xlinker"). Use Apple's toolchain for this build.
unset LD CC CXX AR NM RANLIB CFLAGS CXXFLAGS LDFLAGS CPPFLAGS SDKROOT
mkdir -p build

# Signing: ad-hoc ("-") unless FLUENT_TEAM names your Apple developer team.
if [ -n "${FLUENT_TEAM:-}" ]; then export FLUENT_SIGN_IDENTITY="Apple Development"; else export FLUENT_TEAM="" FLUENT_SIGN_IDENTITY="-"; fi
xcodegen generate --quiet
xcodebuild -project Fluent.xcodeproj -scheme Fluent -configuration "$CONFIG" \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData -quiet build \
  > build/xcodebuild.log 2>&1 || { grep -E "error|BUILD FAILED" build/xcodebuild.log >&2; exit 1; }

rm -rf build/Fluent.app
cp -R "build/DerivedData/Build/Products/$CONFIG/Fluent.app" build/Fluent.app

# The identity must stay the same across builds, or macOS forgets the privacy permissions.
codesign --verify --strict build/Fluent.app
codesign -dv build/Fluent.app 2>&1 | grep -E "^(Identifier|TeamIdentifier|Authority=)" || true
if [ -e build/Fluent.app/Contents/embedded.provisionprofile ]; then
  echo "WARNING: a provisioning profile was embedded; it may expire" >&2
else
  echo "No provisioning profile: nothing expires"
fi
