#!/usr/bin/env bash
set -euo pipefail

# Build for this Mac and sign locally, without requiring an App Store profile.
app_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$app_dir"

mode="${1:-debug}"
if [[ $# -gt 0 ]]; then shift; fi
case "$mode" in
  debug) configuration=Debug; entitlements=DebugProfile ;;
  profile) configuration=Profile; entitlements=DebugProfile ;;
  release) configuration=Release; entitlements=Release ;;
  *) printf 'Usage: %s [debug|profile|release] [flutter build arguments...]\n' "$0" >&2; exit 2 ;;
esac

if [[ -n "${FLUTTER_BIN:-}" ]]; then
  flutter_bin="$FLUTTER_BIN"
elif [[ -x "$app_dir/../.fvm/flutter_sdk/bin/flutter" ]]; then
  flutter_bin="$app_dir/../.fvm/flutter_sdk/bin/flutter"
else
  flutter_bin="$(command -v flutter)"
fi

mkdir -p build
config="$app_dir/build/macos-local.xcconfig"
printf 'ARCHS = %s\nONLY_ACTIVE_ARCH = YES\nCODE_SIGNING_ALLOWED = NO\n' \
  "$(uname -m)" > "$config"
XCODE_XCCONFIG_FILE="$config" "$flutter_bin" build macos "--$mode" --no-pub "$@"

bundle="$app_dir/build/macos/Build/Products/$configuration/$(cat macos/Flutter/ephemeral/.app_filename)"
# Sign nested code first, then apply the sandbox entitlements only to the app.
for framework in "$bundle"/Contents/Frameworks/*.framework; do
  [[ -d "$framework" ]] || continue
  codesign --force --sign - "$framework"
done
for dylib in "$bundle"/Contents/MacOS/*.dylib; do
  [[ -f "$dylib" ]] || continue
  codesign --force --sign - "$dylib"
done
codesign --force --sign - \
  --entitlements "macos/Runner/$entitlements.entitlements" "$bundle"
codesign --verify --deep --strict "$bundle"
printf 'Built and locally signed: %s\n' "$bundle"
