#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo 'Dieser Build benötigt macOS mit vollständig installiertem Xcode.' >&2
  exit 1
fi
xcodebuild -version
xcodebuild -project TimeLaps.xcodeproj -scheme TimeLaps \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
