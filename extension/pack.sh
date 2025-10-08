#!/usr/bin/env sh
# Build a VSIX that already contains the compiled node-pty for code-server.
# POSIX sh compatible (no pipefail).

set -eu

IMG="lscr.io/linuxserver/code-server:4.101.1"
HERE="$(cd "$(dirname "$0")" && pwd)"

docker run --rm \
  -v "$HERE":/ext \
  -w /ext \
  --entrypoint /bin/sh \
  "$IMG" -lc '
    set -eu

    # Install toolchain + Node + npm for the build step
    if command -v apk >/dev/null 2>&1; then
      # Alpine base
      apk add --no-cache make g++ python3 nodejs npm
    else
      # Debian/Ubuntu base
      apt-get update
      apt-get install -y --no-install-recommends make g++ python3 nodejs npm
      rm -rf /var/lib/apt/lists/*
    fi

    # Point node-gyp at code-server embedded Node headers/ABI
    export npm_config_nodedir=/app/code-server/lib/node

    # Clean → install prod deps → rebuild native → package (no extra install)
    rm -f *.vsix
    rm -rf node_modules
    npm ci --omit=dev
    npm rebuild node-pty --runtime=node --force

    npx -y @vscode/vsce package --no-dependencies
  '

echo "VSIX built:"
ls -1 "$HERE"/*.vsix