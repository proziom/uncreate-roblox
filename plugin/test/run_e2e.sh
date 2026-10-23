#!/bin/sh
# Builds uncreate-server, starts it on a scratch directory and runs the e2e test.
# Needs: a C compiler and lune (https://github.com/lune-org/lune) on PATH or in $LUNE.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
LUNE=${LUNE:-lune}
DATA=$(mktemp -d)
PORT=${PORT:-7991}
cc -O2 -std=c11 -o "$DATA/uncreate-server" "$HERE/../../server/uncreate-server.c"
"$DATA/uncreate-server" --port "$PORT" --bind 127.0.0.1 --data "$DATA/project" --key test > "$DATA/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; rm -rf "$DATA"' EXIT
sleep 0.3
cd "$HERE"
UNCREATE_URL="127.0.0.1:$PORT" UNCREATE_KEY=test UNCREATE_SRC="$HERE/../src/" "$LUNE" run e2e.luau
