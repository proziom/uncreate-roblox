#!/bin/sh
# Builds everything a user downloads from Releases into dist/Uncreate-roblox-<version>.zip:
# start-server.bat, Windows + Linux servers, the plugin file and the README.
# Needs: gcc, x86_64-w64-mingw32-gcc (MinGW cross compiler), python3, zip.
# Usage: tools/make_release.sh 1.0.0
set -e
VERSION=${1:?usage: make_release.sh VERSION}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/dist/Uncreate-roblox-$VERSION"
rm -rf "$OUT" && mkdir -p "$OUT/bin"
x86_64-w64-mingw32-gcc -O2 -std=c11 -static -s -o "$OUT/bin/uncreate-server.exe" "$ROOT/server/uncreate-server.c" -lws2_32
gcc -O2 -std=c11 -static -s -o "$OUT/bin/uncreate-server-linux-x86_64" "$ROOT/server/uncreate-server.c"
python3 "$ROOT/plugin/build.py" "$OUT/Uncreate-roblox.rbxmx"
cp "$ROOT/start-server.bat" "$ROOT/README.md" "$ROOT/LICENSE" "$OUT/"
(cd "$ROOT/dist" && rm -f "Uncreate-roblox-$VERSION.zip" && zip -qr "Uncreate-roblox-$VERSION.zip" "Uncreate-roblox-$VERSION")
echo "dist/Uncreate-roblox-$VERSION.zip"
