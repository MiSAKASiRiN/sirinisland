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
signing_identity="${SIRIN_SIGNING_IDENTITY:-Developer ID Application: Zehao Wu (FR76DCGA8Q)}"
(cd Vendor/mediaremote-adapter && xcodebuild -quiet -scheme MediaRemoteAdapter -configuration Release \
  -destination "platform=macOS,arch=$arch" -derivedDataPath "$derived" MACOSX_DEPLOYMENT_TARGET=13.0 CODE_SIGNING_ALLOWED=NO build)
products="$derived/Build/Products/Release"
package="$scratch/SirinIsland.app"
mkdir -p "$package/Contents/"{MacOS,Resources/Licenses,Frameworks}
cp Info.plist "$package/Contents/Info.plist"
mecab="$PWD/Vendor/MeCab"
ditto "$mecab/Resources/MeCab" "$package/Contents/Resources/MeCab"
cp "$mecab"/Licenses/*.txt "$package/Contents/Resources/Licenses/"
xcrun clang++ -std=c++11 -fobjc-arc -target "$arch-apple-macosx13.0" -I"$mecab/include" -c "$mecab/MeCabBridge.mm" -o "$scratch/MeCabBridge.o"
cp Island.icns "$package/Contents/Resources/"
mkdir -p "$package/Contents/Resources/LyricRenderer"
cp WebLyrics/assets/{index.html,renderer.js,renderer.css,strip.css} "$package/Contents/Resources/LyricRenderer/"
cp WebLyrics/licenses/*.txt "$package/Contents/Resources/Licenses/"
for lib in mediaremote-adapter OpenSoftLinking; do
    cp "Vendor/$lib/LICENSE" "$package/Contents/Resources/Licenses/$lib.txt"
done
ditto "$products/PackageFrameworks/MediaRemoteAdapter.framework" "$package/Contents/Frameworks/MediaRemoteAdapter.framework"
ditto "$products/MediaRemoteAdapter_MediaRemoteAdapter.bundle" "$package/Contents/Resources/MediaRemoteAdapter_MediaRemoteAdapter.bundle"
xcrun swiftc -swift-version 5 -O -target "$arch-apple-macosx13.0" -I "$products" -F "$products/PackageFrameworks" \
    -framework MediaRemoteAdapter -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' -import-objc-header "$mecab/MeCabBridge.h" "$scratch/MeCabBridge.o" "$mecab/libmecab.a" -lc++ -liconv Sources/*.swift -o "$package/Contents/MacOS/SirinIsland"
codesign --force --options runtime --sign "$signing_identity" "$package/Contents/Frameworks/MediaRemoteAdapter.framework"
codesign --force --options runtime --sign "$signing_identity" "$package"
codesign --verify --deep --strict "$package"
ditto "$package" "$destination/SirinIsland.app"
echo "$destination/SirinIsland.app"
