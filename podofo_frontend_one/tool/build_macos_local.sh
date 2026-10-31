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
# Qualification uses independent Xcode products AND intermediates. Sharing the
# build database would let Xcode remove the ordinary app as a stale product.
products="${PODOFO_BUILD_PRODUCTS:-$app_dir/build/macos/Build/Products}"
[[ "$products" = /* ]] || { printf 'PODOFO_BUILD_PRODUCTS must be absolute\n' >&2; exit 2; }
if [[ -n "${PODOFO_BUILD_PRODUCTS:-}" ]]; then
  XCODE_XCCONFIG_FILE="$config" "$flutter_bin" build macos "--$mode" --no-pub --config-only "$@"
  XCODE_XCCONFIG_FILE="$config" xcodebuild \
    -workspace "$app_dir/macos/Runner.xcworkspace" \
    -scheme Runner -configuration "$configuration" \
    -derivedDataPath "${products}-derived" \
    -destination "platform=macOS,arch=$(uname -m)" \
    "SYMROOT=$products" "OBJROOT=${products}-derived/Build/Intermediates.noindex" \
    COMPILER_INDEX_STORE_ENABLE=NO -quiet
else
  XCODE_XCCONFIG_FILE="$config" "$flutter_bin" build macos "--$mode" --no-pub "$@"
fi

bundle="$products/$configuration/$(cat macos/Flutter/ephemeral/.app_filename)"
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
if [[ "$mode" = release && "$(uname -m)" = arm64 ]]; then
  python3 tool/audit_podoco_macos.py "$bundle" --report "$products/podoco-assets-audit.json"
fi
printf 'Built and locally signed: %s\n' "$bundle"
