#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
destination="${1:-$PWD/build}"
mkdir -p "$destination"
destination="$(cd "$destination" && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/arcisland.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
derived="${ARC_DERIVED_DATA:-$scratch/DerivedData}"
arch="$(uname -m)"
sparkle="$(scripts/sparkle.sh)"
signing_identity="${SIRIN_SIGNING_IDENTITY:-Developer ID Application: Zehao Wu (FR76DCGA8Q)}"
(cd Vendor/mediaremote-adapter && xcodebuild -quiet -scheme MediaRemoteAdapter -configuration Release \
  -destination "platform=macOS,arch=$arch" -derivedDataPath "$derived" MACOSX_DEPLOYMENT_TARGET=13.0 CODE_SIGNING_ALLOWED=NO build)
products="$derived/Build/Products/Release"
term_scratch="$PWD/build/TerminalSupport"
term_args=(--package-path TerminalSupport --scratch-path "$term_scratch" -c release)
swift build "${term_args[@]}" --product TerminalSupport
term_products="$(swift build "${term_args[@]}" --show-bin-path)"
term_modules="$term_products"
if [[ -d "$term_products/Modules" ]]; then term_modules="$term_products/Modules"; fi
package="$scratch/SirinIsland.app"
mkdir -p "$package/Contents/"{MacOS,Resources/Licenses,Frameworks}
cp Info.plist "$package/Contents/Info.plist"
if [[ -n "${UPDATE_CDN_ORIGIN:-}${SPARKLE_PUBLIC_KEY:-}${GITHUB_UPDATE_REPOSITORY:-}" ]]; then
    python3 scripts/release/configure.py "$package/Contents/Info.plist"
fi
ditto "$sparkle/Sparkle.framework" "$package/Contents/Frameworks/Sparkle.framework"
cp "$sparkle/LICENSE" "$package/Contents/Resources/Licenses/Sparkle.txt"
mecab="$PWD/Vendor/MeCab"
ditto "$mecab/Resources/MeCab" "$package/Contents/Resources/MeCab"
cp "$mecab"/Licenses/*.txt "$package/Contents/Resources/Licenses/"
xcrun clang++ -std=c++11 -fobjc-arc -target "$arch-apple-macosx13.0" -I"$mecab/include" -c "$mecab/MeCabBridge.mm" -o "$scratch/MeCabBridge.o"
cp "$term_scratch/checkouts/SwiftTerm/LICENSE" "$package/Contents/Resources/Licenses/SwiftTerm.txt"
cp Island.icns "$package/Contents/Resources/"
mkdir -p "$package/Contents/Resources/LyricRenderer"
cp WebLyrics/assets/{index.html,renderer.js,renderer.css,strip.css} "$package/Contents/Resources/LyricRenderer/"
cp WebLyrics/licenses/*.txt "$package/Contents/Resources/Licenses/"
for lib in mediaremote-adapter OpenSoftLinking; do
    cp "Vendor/$lib/LICENSE" "$package/Contents/Resources/Licenses/$lib.txt"
done
ditto "$products/PackageFrameworks/MediaRemoteAdapter.framework" "$package/Contents/Frameworks/MediaRemoteAdapter.framework"
ditto "$products/MediaRemoteAdapter_MediaRemoteAdapter.bundle" "$package/Contents/Resources/MediaRemoteAdapter_MediaRemoteAdapter.bundle"
xcrun swiftc -swift-version 5 -O -target "$arch-apple-macosx13.0" -I "$products" -I "$term_modules" "$term_products/libTerminalSupport.a" -F "$products/PackageFrameworks" \
    -F "$sparkle" -framework Sparkle -framework MediaRemoteAdapter -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' -import-objc-header "$mecab/MeCabBridge.h" "$scratch/MeCabBridge.o" "$mecab/libmecab.a" -lc++ -liconv Sources/*.swift -o "$package/Contents/MacOS/SirinIsland"
sign=(codesign --force --options runtime --sign "$signing_identity")
if [[ "$signing_identity" != "-" ]]; then sign+=(--timestamp); fi
frameworks="$package/Contents/Frameworks"
sparkle_version="$frameworks/Sparkle.framework/Versions/Current"
for component in "$sparkle_version"/XPCServices/*.xpc "$sparkle_version/Updater.app" "$sparkle_version/Autoupdate"; do
    "${sign[@]}" --preserve-metadata=entitlements "$component"
done
"${sign[@]}" "$frameworks/Sparkle.framework"
"${sign[@]}" "$frameworks/MediaRemoteAdapter.framework"
"${sign[@]}" "$package"
codesign --verify --deep --strict "$package"
ditto "$package" "$destination/SirinIsland.app"
echo "$destination/SirinIsland.app"
