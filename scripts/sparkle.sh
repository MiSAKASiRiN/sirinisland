#!/bin/bash
# Print the directory of the verified Sparkle distribution for build and release tools.
set -euo pipefail
cd "$(dirname "$0")/.."
version=2.10.1
digest=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
cache="$PWD/build/sparkle"
archive="$cache/Sparkle-$version.tar.xz"
mkdir -p "$cache"
scratch=$(mktemp -d "$cache/unpack.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
if [[ ! -f "$archive" ]]; then
    curl -fLsS --retry 3 "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" -o "$scratch/download"
    echo "$digest  $scratch/download" | shasum -a 256 -c - >&2
    mv "$scratch/download" "$archive"
fi
echo "$digest  $archive" | shasum -a 256 -c - >&2
if [[ ! -d "$cache/$version" ]]; then
    mkdir "$scratch/$version"
    tar -xf "$archive" -C "$scratch/$version" ./bin ./Sparkle.framework ./LICENSE
    # os.rename is atomic, including when another build finishes extracting first.
    python3 - "$scratch/$version" "$cache/$version" <<'PY'
import errno, os, sys
try:
    os.rename(*sys.argv[1:])
except OSError as error:
    if error.errno not in (errno.ENOTEMPTY, errno.EEXIST):
        raise
PY
fi
echo "$cache/$version"
