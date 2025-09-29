#!/command/with-contenv sh
set -eu

mkdir -p /config/data/User /config/workspace

# Ensure the real settings file exists
[ -f /config/data/User/keybindings.json ] || printf '{}' >/config/data/User/keybindings.json

# If workspace file isn't a hardlink to the real file, replace it with one
SRC=/config/data/User/keybindings.json
DST=/config/workspace/keybindings.json

# compare inode numbers; if different (or dst missing), recreate hardlink
SRC_INO="$(ls -i "$SRC" | awk '{print $1}')"
DST_INO="$(ls -i "$DST" 2>/dev/null | awk '{print $1}' || echo '')"

if [ "$SRC_INO" != "$DST_INO" ]; then
  rm -f "$DST"
  ln "$SRC" "$DST"   # hard link (NOT symlink)
fi
