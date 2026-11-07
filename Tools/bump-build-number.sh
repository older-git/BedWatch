#!/bin/sh
# Scheme pre-action: bump the build number before every build. watchOS keeps a complication
# extension (and its cached drawing) when the build number is unchanged, so every install
# needs a new one. App and extension both read it from Config/BuildNumber.xcconfig.
set -e
f="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}/Config/BuildNumber.xcconfig"
n=$(sed -n 's/^CURRENT_PROJECT_VERSION = //p' "$f" 2>/dev/null || true)   # missing on a fresh checkout
printf 'CURRENT_PROJECT_VERSION = %s\n' "$(( ${n:-1} + 1 ))" > "$f"
