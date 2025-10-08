#!/usr/bin/env sh
# Build a VSIX that already contains the compiled node-pty for code-server.

set -euo pipefail

IMG="lscr.io/linuxserver/code-server:4.101.1"
HERE="$(cd "$(dirname "$0")" && pwd)"

docker run --rm \
  -v "$HERE":/ext \
  -w /ext \
  --entrypoint /bin/sh \
  "$IMG" -lc '
    set -e

    # Detect base and install build toolchain + npm
    if command -v apk >/dev/null 2>&1; then
      # Alpine
      apk add --no-cache make g++ python3 npm
    else
      # Debian/Ubuntu
      apt-get update
      apt-get install -y --no-install-recommends make g++ python3 npm
      rm -rf /var/lib/apt/lists/*
    fi

    # Point node-gyp at code-server\'s embedded Node headers
    export npm_config_nodedir=/app/code-server/lib/node

    npm run clean
    npm run deps
    npm run rebuild:embed

    npx -y @vscode/vsce package --no-dependencies
  '

echo "VSIX built:"
ls -1 "$HERE"/*.vsix