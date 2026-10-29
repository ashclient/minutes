#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
if [[ "$(uname -s)" != Darwin ]]; then
  echo "Minutes is a native macOS app. Build on macOS 14 or newer."
  exit 1
fi
if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Apple Command Line Tools are required. Running Apple's installer…"
  xcode-select --install || true
  echo "After installation completes, open build.command again."
  exit 1
fi
export MACOSX_DEPLOYMENT_TARGET=14.0
printf 'Checking Minutes…\n'
check_dir="$(mktemp -d)"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library Sources/Minutes/Models.swift Sources/Minutes/AIClient.swift Sources/Minutes/NotesLength.swift Sources/Minutes/OrderedBatch.swift Checks/CoreChecks.swift -o "$check_dir/MinutesChecks"
"$check_dir/MinutesChecks"
printf 'Building Minutes for this Mac…\n' 
if [[ "${MINUTES_RUN_TESTS:-0}" == "1" ]]; then
  swift test
else
  echo "Building app only. XCTest tests require full Xcode; set MINUTES_RUN_TESTS=1 to run them."
fi
build_args=(-c release)
if [[ "${MINUTES_UNIVERSAL:-0}" == "1" ]]; then
  build_args+=(--arch arm64 --arch x86_64)
fi
swift build "${build_args[@]}"
binary_dir="$(swift build "${build_args[@]}" --show-bin-path)"
app_dir="$PWD/dist/Minutes.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/Minutes" "$app_dir/Contents/MacOS/Minutes"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp Resources/Guide.html "$app_dir/Contents/Resources/Guide.html"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$app_dir/Contents/Resources/"; fi
# An ad-hoc signature permits a locally built app to run, but is not notarization.
codesign --force --deep --sign - "$app_dir"
echo "Built: $app_dir"
echo "Drag Minutes.app into Applications, then open it."
if [[ "${CI:-false}" != "true" ]]; then open -R "$app_dir"; fi
