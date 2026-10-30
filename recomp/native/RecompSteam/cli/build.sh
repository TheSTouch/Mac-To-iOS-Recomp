#!/bin/sh
# Builds recomp-steam-cli for this Mac from the Steam runtime's sources, into
# build/recomp-steam/ at the repository root (or the folder given as $1).
set -e
here=$(cd "$(dirname "$0")" && pwd)
src=$(dirname "$here")
root=$(cd "$src/../../.." && pwd)
kettle=$root/recomp/vendor/kettle/Sources/KettleExperimental
out=${1:-$root/build/recomp-steam}
if [ ! -f "$kettle/KettleFeatures.h" ]; then
    echo "recomp/vendor/kettle is empty: run git submodule update --init recomp/vendor/kettle" >&2
    exit 1
fi
mkdir -p "$out"
# The runtime's sources as the ports build them (recomp/steam_runtime.py): every top-level
# C/Objective-C file here and in Kettle's core, with Kettle's defaults plus concurrent play.
set --
for f in "$src"/*.c "$src"/*.m "$kettle"/*.c "$kettle"/*.m; do
    if [ -e "$f" ]; then set -- "$@" "$f"; fi
done
xcrun clang -fobjc-arc -fmodules -O1 -g -Wall -Wno-unused-function -mmacosx-version-min=12.0 \
    -framework Foundation -framework Security -framework CoreImage -framework ImageIO \
    -DKETTLE_CONCURRENT_PLAY=1 -I "$src" -I "$kettle/include" -I "$kettle" \
    -DRECOMP_STEAM_CLI=1 "$@" "$here/recomp-steam-cli.m" -o "$out/recomp-steam-cli"
codesign -s - -f "$out/recomp-steam-cli" >/dev/null 2>&1
echo "$out/recomp-steam-cli"
