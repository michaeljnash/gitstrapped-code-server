#!/usr/bin/env sh
set -eu

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

WORKSPACE_DIR="${WORKSPACE_DIR:-/config/workspace}"
NEW_UDD="${WORKSPACE_DIR%/}/config"           # /config/workspace/config
NEW_USER_DIR="${NEW_UDD}/User"                # /config/workspace/config/User
RUN_PATH="/etc/services.d/code-server/run"
BAK_PATH="/etc/services.d/code-server/run.codestrap.bak"

# ---- Ensure dirs + baseline files (real files) ----
mkdir -p "$NEW_USER_DIR"
[ -f "$NEW_USER_DIR/settings.json"    ] || printf '{}\n' >"$NEW_USER_DIR/settings.json"
[ -f "$NEW_USER_DIR/tasks.json"       ] || printf '{}\n' >"$NEW_USER_DIR/tasks.json"
[ -f "$NEW_USER_DIR/keybindings.json" ] || printf '[]\n' >"$NEW_USER_DIR/keybindings.json"
[ -f "$NEW_USER_DIR/extensions.json"  ] || printf '{ "recommendations": [] }\n' >"$NEW_USER_DIR/extensions.json"
chown -R "$PUID:$PGID" "$WORKSPACE_DIR" 2>/dev/null || true

# ---- Patch the LinuxServer service to point to our user-data-dir ----
if [ -f "$RUN_PATH" ]; then
  if ! grep -q -- '--user-data-dir' "$RUN_PATH"; then
    cp -f "$RUN_PATH" "$BAK_PATH"
    # Insert our flag right after the first 'code-server' token
    awk -v UDD="$NEW_UDD" '
      BEGIN{done=0}
      {
        if(!done && $0 ~ /code-server/){
          sub(/code-server/, "code-server --user-data-dir " UDD);
          done=1
        }
        print
      }
    ' "$BAK_PATH" > "$RUN_PATH.tmp"
    mv -f "$RUN_PATH.tmp" "$RUN_PATH"
    chmod +x "$RUN_PATH"
    echo "[codestrap] patched service run to use --user-data-dir ${NEW_UDD}"
  else
    echo "[codestrap] service run already has --user-data-dir (leaving as-is)"
  fi
else
  echo "[codestrap][WARN] ${RUN_PATH} not found; cannot patch service. (Image change?)"
fi

# ---- Also write YAML for completeness (no harm if CLI overrides) ----
CFG="$HOME/.config/code-server/config.yaml"
mkdir -p "$(dirname "$CFG")"
# remove any pre-existing user-data-dir line
[ -f "$CFG" ] && grep -v '^[[:space:]]*user-data-dir:' "$CFG" > "${CFG}.tmp" && mv -f "${CFG}.tmp" "$CFG"
printf 'user-data-dir: %s\n' "$NEW_UDD" >> "$CFG"
chown -R "$PUID:$PGID" "$HOME/.config" 2>/dev/null || true
echo "[codestrap] wrote config.yaml user-data-dir → $NEW_UDD"

# ---- Trigger supervised restart so the new flag takes effect ----
if command -v s6-svscanctl >/dev/null 2>&1; then
  # signal a supervised shutdown; s6 will restart the stack
  s6-svscanctl -t /run/s6 >/dev/null 2>&1 || true
else
  # best-effort fallback: kill code-server; s6 should bring it back
  pkill -f "[c]ode-server" >/dev/null 2>&1 || true
fi
