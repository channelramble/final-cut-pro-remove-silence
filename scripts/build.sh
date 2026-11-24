#!/bin/bash
# Builds "Silence Remover.app" (with the Final Cut Pro workflow extension inside) into build/.
#
#   scripts/build.sh                 build + sign
#   SIGN_IDENTITY=- scripts/build.sh ad-hoc signature instead of a developer certificate
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FCP_FRAMEWORK="vendor/fcp/Frameworks/ProExtension.framework"
if [ ! -d "$FCP_FRAMEWORK" ]; then
  # The extension runtime ships inside Final Cut Pro; borrow it from there.
  for app in "/Applications/Final Cut Pro Creator Studio.app" "/Applications/Final Cut Pro.app" "/Applications/Final Cut Pro Trial.app"; do
    if [ -d "$app/Contents/Frameworks/ProExtension.framework" ]; then
      mkdir -p vendor/fcp/Frameworks
      cp -R "$app/Contents/Frameworks/ProExtension.framework" vendor/fcp/Frameworks/
      break
    fi
  done
fi
[ -d "$FCP_FRAMEWORK" ] || { echo "ProExtension.framework not found. Install Final Cut Pro, or copy the framework to $FCP_FRAMEWORK" >&2; exit 1; }

xcodegen generate --quiet
xcodebuild -project SilenceRemover.xcodeproj -scheme SilenceRemover -configuration Release \
  -derivedDataPath build/DerivedData ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
  -quiet build

APP="build/Silence Remover.app"
rm -rf "$APP"
cp -R "build/DerivedData/Build/Products/Release/Silence Remover.app" "$APP"
APPEX="$APP/Contents/PlugIns/Remove Silence.appex"

# Sign inside-out: runtime framework, extension (sandboxed), then the app.
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
  [ -n "$IDENTITY" ] || IDENTITY="-"
fi
echo "Signing with: $IDENTITY"
codesign --force --timestamp=none -s "$IDENTITY" "$APPEX/Contents/Frameworks/ProExtension.framework"
codesign --force --timestamp=none -s "$IDENTITY" --entitlements App/Extension/Extension.entitlements "$APPEX"
codesign --force --timestamp=none -s "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
