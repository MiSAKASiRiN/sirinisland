#!/bin/bash
# Generate and sign independent feeds over one immutable ZIP, with no delta updates.
set -euo pipefail
sparkle="$(scripts/sparkle.sh)"
appcast_args=(--maximum-deltas 0)
if [[ "$TAG" == *-beta.* ]]; then appcast_args+=(--channel beta); fi
for channel in github cdn; do
    case "$channel" in
        github) prefix="https://github.com/$GITHUB_UPDATE_REPOSITORY/releases/download/$TAG/" ;;
        cdn) prefix="${UPDATE_CDN_ORIGIN%/}/sirinisland/releases/$TAG/" ;;
    esac
    output="$DIST/$channel/appcast.xml"
    mkdir -p "$(dirname "$output")"
    if [[ ! -f "$output" ]]; then
        printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$sparkle/bin/generate_appcast" --ed-key-file - \
            "${appcast_args[@]}" --download-url-prefix "$prefix" -o "$output" "$(dirname "$ARCHIVE")"
        if [[ "$TAG" == *-beta.* ]]; then
            # Keep CFBundleShortVersionString numeric in the app; show the beta number in Sparkle.
            python3 - "$output" "${TAG#v}" <<'PY'
import sys
import xml.etree.ElementTree as ET

namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", namespace)
feed = ET.parse(sys.argv[1])
item = feed.find("./channel/item")
item.find("title").text = sys.argv[2]
item.find(f"{{{namespace}}}shortVersionString").text = sys.argv[2]
feed.write(sys.argv[1], encoding="utf-8", xml_declaration=True)
PY
            printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$sparkle/bin/sign_update" --ed-key-file - "$output"
        fi
    fi
    printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$sparkle/bin/sign_update" --ed-key-file - --verify "$output"
done
xcrun swift scripts/release/verify-archive.swift "$ARCHIVE" "$SPARKLE_PUBLIC_KEY" \
    "$DIST/github/appcast.xml" "$DIST/cdn/appcast.xml"
