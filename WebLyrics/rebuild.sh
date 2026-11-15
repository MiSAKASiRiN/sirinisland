#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
root="$(cd "$1" && pwd)"
core="$root/packages/core"
compiler=( "$root"/node_modules/.pnpm/@esbuild+darwin-*/node_modules/@esbuild/darwin-*/bin/esbuild )
"${compiler[0]}" strip.ts --bundle --platform=browser --format=iife --target=safari16.4 \
    "--alias:#utils/line-balancer.ts=$PWD/single-line-balancer.ts" \
    --alias:amll-engine="$core/src/lyric-player/dom/index.ts" --alias:amll-styles="$core/src/styles/lyric-player.module.css" \
    --define:import.meta.env.DEV=false --outfile=assets/renderer.js --sourcemap=external
