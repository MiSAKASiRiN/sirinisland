#!/bin/bash
set -euo pipefail
umask 077
tmp=$(mktemp -d)
keychain="$tmp/signing.keychain-db"
trap 'security delete-keychain "$keychain" 2>/dev/null || true; rm -rf "$tmp"' EXIT
printf '%s' "$APPLE_CERTIFICATE_P12_BASE64" | base64 -D > "$tmp/signing.p12"
if [[ -n "${NOTARY_API_KEY_P8:-}" ]]; then
    printf '%s' "$NOTARY_API_KEY_P8" > "$tmp/AuthKey.p8"
    auth=(--key "$tmp/AuthKey.p8" --key-id "${NOTARY_KEY_ID:?missing NOTARY_KEY_ID}" --issuer "${NOTARY_ISSUER_ID:?missing NOTARY_ISSUER_ID}")
else
    auth=(--apple-id "${NOTARY_APPLE_ID:?missing NOTARY_APPLE_ID}" --team-id "$APPLE_TEAM_ID" --password "$NOTARY_APP_PASSWORD")
fi
password=$(openssl rand -hex 32)
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 7200 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$tmp/signing.p12" -k "$keychain" -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" "$HOME/Library/Keychains/login.keychain-db"
identity=$(security find-identity -v -p codesigning "$keychain" | awk -v team="($APPLE_TEAM_ID)" '/Developer ID Application:/ && index($0, team) {print $2}')
[[ "$identity" =~ ^[A-F0-9]{40}$ ]] || { echo "Expected one Developer ID Application identity for APPLE_TEAM_ID" >&2; exit 1; }
unset APPLE_CERTIFICATE_PASSWORD APPLE_CERTIFICATE_P12_BASE64 NOTARY_API_KEY_P8 NOTARY_APP_PASSWORD NOTARY_APPLE_ID password
umask 022
SIRIN_SIGNING_IDENTITY="$identity" ./build.sh "$tmp/product"
app="$tmp/product/SirinIsland.app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$tmp/submit.zip"
xcrun notarytool submit "$tmp/submit.zip" "${auth[@]}" --wait --output-format json > "$tmp/notary.json"
cat "$tmp/notary.json"
if [[ "$(plutil -extract status raw "$tmp/notary.json")" != Accepted ]]; then
    xcrun notarytool log "$(plutil -extract id raw "$tmp/notary.json")" "${auth[@]}"
    exit 1
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$ARCHIVE"
