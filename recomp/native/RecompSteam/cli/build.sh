#!/bin/sh
# Builds recomp-steam-cli for this Mac from the RecompSteam sources, into
# build/recomp-steam/ at the repository root (or the folder given as $1).
set -e
here=$(cd "$(dirname "$0")" && pwd)
src=$(dirname "$here")
root=$(cd "$src/../../.." && pwd)
out=${1:-$root/build/recomp-steam}
mkdir -p "$out"
# The runtime's own sources, minus what only a port links (the flat API and the
# other sessions' game-facing files stay out of the CLI).
set --
for f in "$src"/RecompSteamProto.c "$src"/RecompSteamUtil.c "$src"/RecompSteamSession.m "$src"/RecompSteamAuth.m; do
    set -- "$@" "$f"
done
xcrun clang -fobjc-arc -fmodules -O1 -g -Wall -Wno-unused-function -mmacosx-version-min=12.0 \
    -framework Foundation -framework Security -framework CoreImage -framework ImageIO \
    -DRECOMP_STEAM_CLI=1 "$@" "$here/recomp-steam-cli.m" -o "$out/recomp-steam-cli"
codesign -s - -f "$out/recomp-steam-cli" >/dev/null 2>&1
echo "$out/recomp-steam-cli"
