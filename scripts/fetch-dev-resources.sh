#!/bin/bash
# Fetches the things this repository deliberately does not include:
#
#   vendor/fcp      Final Cut Pro's extension runtime (ProExtension.framework) — Apple's, copied
#                   from your installed Final Cut Pro; needed to build the extension.
#   vendor/dtd      Final Cut Pro's FCPXML DTDs — Apple's, copied from your installed Final Cut
#                   Pro; the tests validate everything they produce against them.
#   vendor/samples  Real FCPXML exports from https://github.com/orchetect/swift-fcpxml (MIT);
#                   the structural tests run over them.
set -euo pipefail
cd "$(dirname "$0")/.."

FCP=""
for app in "/Applications/Final Cut Pro Creator Studio.app" "/Applications/Final Cut Pro.app" "/Applications/Final Cut Pro Trial.app"; do
  [ -d "$app" ] && FCP="$app" && break
done
if [ -n "$FCP" ]; then
  mkdir -p vendor/fcp/Frameworks vendor/dtd
  rm -rf vendor/fcp/Frameworks/ProExtension.framework
  cp -R "$FCP/Contents/Frameworks/ProExtension.framework" vendor/fcp/Frameworks/
  cp "$FCP/Contents/Frameworks/Interchange.framework/Versions/A/Resources/"FCPXMLv1_*.dtd vendor/dtd/
  echo "Copied ProExtension.framework and DTDs from $FCP"
else
  echo "Final Cut Pro isn't installed here: skipping vendor/fcp and vendor/dtd." >&2
  echo "(The engine and its tests still build; the app needs ProExtension.framework.)" >&2
fi

if [ ! -d vendor/samples/swift-fcpxml ]; then
  mkdir -p vendor/samples
  git clone --depth 1 --quiet https://github.com/orchetect/swift-fcpxml.git vendor/samples/swift-fcpxml
  echo "Downloaded sample FCPXML exports"
fi
