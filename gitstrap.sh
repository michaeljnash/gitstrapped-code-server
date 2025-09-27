#!/usr/bin/env sh
# gitstrap — bootstrap GitHub + manage code-server auth (CLI-only)
set -eu

# =========================
# Version (simple & explicit)
# =========================
VERSION="${GITSTRAP_VERSION:-0.1.0}"

# =========================
# Small utilities
# =========================
log(){ echo "[gitstrap] $*"; }
warn(){ echo "[gitstrap][WARN] $*" >&2; }
redact(){ echo "$1" | sed 's/[A-Za-z0-9_\-]\{12,\}/***REDACTED***/g'; }

ensure_dir(){ mkdir -p "$1" 2>/dev/null || true; chown -R "${PUID:-1000}:${PGID:-1000}" "$1" 2>/dev/null || true; }
is_tty(){ [ -t 0 ] && [ -t 1 ]; }
prompt(){ printf "%s" "$1"; read -r _ans || true; printf "%s" "${_ans:-}"; }
prompt_def(){ v="$(prompt "$1")"; [ -n "$v" ] && printf "%s" "$v" || printf "%s" "$2"; }
prompt_secret(){
  printf "%s" "$1" >/dev/tty 2>/dev/null || printf "%s" "$1"
  stty -echo 2>/dev/null || true
  read -r s || true
  stty echo 2>/dev/null || true
  printf "\n" >/dev/tty 2>/dev/null || true
  printf "%s" "${s:-}"
}
yn_to_bool(){ case "$(printf "%s" "$1" | tr '[:upper:]' '[:lower:]')" in y|yes|t|true|1) echo "true";; *) echo "false";; esac; }
normalize_bool(){ v="${1:-true}"; [ "$(printf '%s' "$v" | cut -c1 | tr '[:upper:]' '[:lower:]')" = "f" ] && echo false || echo true; }

print_help(){
cat <<'HLP'
gitstrap — bootstrap GitHub + manage code-server auth

Usage:
  gitstrap               # interactive bootstrap (prompts if TTY)
  gitstrap --env         # bootstrap using environment variables only
  gitstrap passwd        # interactive password change (secure prompts)
  gitstrap -h | --help   # help
  gitstrap -v | --version# version

Environment (used by --env or as defaults in prompts):
  GH_USERNAME, GH_PAT (classic: user:email, admin:public_key)  [required to bootstrap]
  GIT_NAME, GIT_EMAIL, GH_REPOS, PULL_EXISTING_REPOS=true|false
  GIT_BASE_DIR=/config/workspace, GH_KEY_TITLE

Examples:
  gitstrap
  gitstrap --env
  gitstrap passwd
HLP
}

print_version(){ echo "gitstrap ${VERSION}"; }

# =========================
# Environment / paths
# =========================
export HOME="${HOME:-/config}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

STATE_DIR="$HOME/.gitstrap"; ensure_dir "$STATE_DIR"
LOCK_DIR="/run/gitstrap";    ensure_dir "$LOCK_DIR"
LOCK_FILE="$LOCK_DIR/init-gitstrap.lock"

PASS_HASH_PATH="${FILE__HASHED_PASSWORD:-$STATE_DIR/password.hash}"
FIRSTBOOT_MARKER="$STATE_DIR/.firstboot-auth-restart"

BASE="${GIT_BASE_DIR:-$HOME/workspace}"; ensure_dir "$BASE"
SSH_DIR="$HOME/.ssh"; ensure_dir "$SSH_DIR"
KEY_NAME="id_ed25519"
PRIVATE_KEY_PATH="$SSH_DIR/$KEY_NAME"
PUBLIC_KEY_PATH="$SSH_DIR/${KEY_NAME}.pub"

# =========================
# Restart gate (tiny HTTP)
# =========================
install_restart_gate(){
  NODE_BIN=""
  for p in /usr/local/bin/node /usr/bin/node /app/code-server/lib/node /usr/lib/code-server/lib/node; do
    [ -x "$p" ] && { NODE_BIN="$p"; break; }
  done
  [ -n "$NODE_BIN" ] || { warn "Node not found; restart gate disabled"; return 0; }

  mkdir -p /usr/local/bin
  cat >/usr/local/bin/restartgate.js <<'EOF'
const http = require('http');
const { exec } = require('child_process');
const PORT = 9000, HOST = '127.0.0.1';
function supervisedRestart(){
  const cmd = "sh -c 'for i in 1 2 3 4 5; do [ -p /run/s6/scan-control ] && break; sleep 0.4; done; s6-svscanctl -t /run/s6 >/dev/null 2>&1 || kill -TERM 1 >/dev/null 2>&1'";
  exec(cmd, () => {});
}
const srv = http.createServer((req,res)=>{
  const url = (req.url || '/').split('?')[0];
  if (url === '/health'){ res.writeHead(200,{'Content-Type':'text/plain'}).end('OK'); return; }
  if (url === '/restart'){ res.writeHead(200,{'Content-Type':'text/plain'}).end('OK'); supervisedRestart(); return; }
  res.writeHead(200,{'Content-Type':'text/plain'}).end('OK');
});
srv.listen(PORT, HOST, ()=>console.log(`[restartgate] listening on ${HOST}:${PORT} (/restart, /health)`));
EOF
  chmod 755 /usr/local/bin/restartgate.js

  mkdir -p /etc/services.d/restartgate
  cat >/etc/services.d/restartgate/run <<EOF
#!/usr/bin/env sh
MARKER="$FIRSTBOOT_MARKER"
if [ -f "\$MARKER" ]; then
  echo "[restartgate] first-boot marker found; scheduling supervised restart"
  rm -f "\$MARKER" || true
  (
    for i in 1 2 3 4 5; do [ -p /run/s6/scan-control ] && break; sleep 0.4; done
    s6-svscanctl -t /run/s6 >/dev/null 2>&1 || kill -TERM 1 >/dev/null 2>&1
  ) &
fi
exec "$NODE_BIN" /usr/local/bin/restartgate.js
EOF
  chmod +x /etc/services.d/restartgate/run
  echo '#!/usr/bin/env sh\nexit 0' >/etc/services.d/restartgate/finish && chmod +x /etc/services.d/restartgate/finish
  log "installed restart gate service"
}

trigger_restart_gate(){
  command -v curl >/dev/null 2>&1 && curl -fsS --max-time 3 "http://127.0.0.1:9000/restart" >/dev/null 2>&1 || true
}

# =========================
# First-boot default password
# =========================
init_default_password(){
  DEFAULT_PASSWORD="${DEFAULT_PASSWORD:-}"
  [ -n "$DEFAULT_PASSWORD" ] || { log "DEFAULT_PASSWORD not set; skipping default hash"; return 0; }
  [ -s "$PASS_HASH_PATH" ] && { log "hash exists; leaving as-is"; return 0; }

  tries=0
  until command -v argon2 >/dev/null 2>&1; do tries=$((tries+1)); [ $tries -ge 20 ] && { warn "argon2 not found"; return 0; }; sleep 1; done

  ensure_dir "$(dirname "$PASS_HASH_PATH")"
  salt="$(head -c16 /dev/urandom | base64)"
  hash="$(printf '%s' "$DEFAULT_PASSWORD" | argon2 "$salt" -id -e)"
  printf '%s' "$hash" > "$PASS_HASH_PATH"
  chmod 644 "$PASS_HASH_PATH" || true
  chown "$PUID:$PGID" "$PASS_HASH_PATH" 2>/dev/null || true
  : > "$FIRSTBOOT_MARKER"
  log "wrote initial password hash"
}

# =========================
# Password change (interactive)
# =========================
password_change_interactive(){
  command -v argon2 >/dev/null 2>&1 || { echo "argon2 not found." >&2; return 1; }
  NEW="$(prompt_secret "New code-server password: ")"
  CONF="$(prompt_secret "Confirm password: ")"
  [ -n "$NEW" ] || { echo "Error: password required." >&2; return 1; }
  [ -n "$CONF" ] || { echo "Error: confirmation required." >&2; return 1; }
  [ "$NEW" = "$CONF" ] || { echo "Error: passwords do not match." >&2; return 1; }
  [ ${#NEW} -ge 8 ] || { echo "Error: minimum length 8." >&2; return 1; }

  salt="$(head -c16 /dev/urandom | base64)"
  hash="$(printf '%s' "$NEW" | argon2 "$salt" -id -e)"
  printf '%s' "$hash" > "$PASS_HASH_PATH"
  chmod 644 "$PASS_HASH_PATH" || true
  chown "$PUID:$PGID" "$PASS_HASH_PATH" 2>/dev/null || true

  printf "\n\033[1;33m*** CODE-SERVER PASSWORD CHANGED ***\n*** REFRESH PAGE TO LOGIN ***\033[0m\n\n"
  trigger_restart_gate
}

# =========================
# Git bootstrap internals
# =========================
resolve_email(){
  GH_USERNAME="${GH_USERNAME:-}"; GH_PAT="${GH_PAT:-}"
  [ -n "$GH_PAT" ] || { echo "${GH_USERNAME:-unknown}@users.noreply.github.com"; return; }
  EMAILS="$(curl -fsS -H "Authorization: token ${GH_PAT}" -H "Accept: application/vnd.github+json" https://api.github.com/user/emails || true)"
  PRIMARY="$(printf "%s" "$EMAILS" | awk -F\" '/"email":/ {e=$4} /"primary": *true/ {print e; exit}')"
  [ -n "${PRIMARY:-}" ] && { echo "$PRIMARY"; return; }
  VERIFIED="$(printf "%s" "$EMAILS" | awk -F\" '/"email":/ {e=$4} /"verified": *true/ {print e; exit}')"
  [ -n "${VERIFIED:-}" ] && { echo "$VERIFIED"; return; }
  PUB_JSON="$(curl -fsS -H "Accept: application/vnd.github+json" "https://api.github.com/users/${GH_USERNAME}" || true)"
  PUB_EMAIL="$(printf "%s" "$PUB_JSON" | awk -F\" '/"email":/ {print $4; exit}')"
  [ -n "${PUB_EMAIL:-}" ] && [ "$PUB_EMAIL" != "null" ] && { echo "$PUB_EMAIL"; return; }
  echo "${GH_USERNAME:-unknown}@users.noreply.github.com"
}

git_upload_key(){
  GH_PAT="${GH_PAT:-}"; GH_KEY_TITLE="${GH_KEY_TITLE:-gitstrapped-code-server SSH Key}"
  [ -n "$GH_PAT" ] || { warn "GH_PAT empty; cannot upload SSH key"; return 0; }
  LOCAL_KEY="$(awk '{print $1" "$2}' "$PUBLIC_KEY_PATH")"
  KEYS_JSON="$(curl -fsS -H "Authorization: token ${GH_PAT}" -H "Accept: application/vnd.github+json" https://api.github.com/user/keys || true)"
  echo "$KEYS_JSON" | grep -q "\"key\": *\"$LOCAL_KEY\"" && { log "SSH key already on GitHub"; return 0; }
  RESP="$(curl -fsS -X POST -H "Authorization: token ${GH_PAT}" -H "Accept: application/vnd.github+json" \
      -d "{\"title\":\"$GH_KEY_TITLE\",\"key\":\"$LOCAL_KEY\"}" https://api.github.com/user/keys || true)"
  echo "$RESP" | grep -q '"id"' && log "SSH key added" || warn "Key upload failed: $(redact "$RESP")"
}

clone_one(){
  spec="$1"; PULL="${2:-true}"
  spec="$(echo "$spec" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"; [ -n "$spec" ] || return 0
  repo="$spec"; branch=""
  case "$spec" in *'#'*) branch="${spec#*#}"; repo="${spec%%#*}";; esac
  case "$repo" in
    *"git@github.com:"*) url="$repo"; name="$(basename "$repo" .git)";;
    http*://github.com/*|ssh://git@github.com/*)
      name="$(basename "$repo" .git)"
      owner_repo="$(echo "$repo" | sed -E 's#^https?://github\.com/##; s#^ssh://git@github\.com/##')"
      owner_repo="${owner_repo%.git}"
      url="git@github.com:${owner_repo}.git"
      ;;
    */*) name="$(basename "$repo")"; url="git@github.com:${repo}.git";;
    *) log "skip invalid spec: $spec"; return 0;;
  esac
  dest="${BASE}/${name}"
  safe_url="$(echo "$url" | sed -E 's#(git@github\.com:).*#\1***.git#')"

  if [ -d "$dest/.git" ]; then
    if [ "$(normalize_bool "$PULL")" = "true" ]; then
      log "pull: ${name}"
      git -C "$dest" fetch --all -p || true
      if [ -n "$branch" ]; then git -C "$dest" checkout "$branch" || true; git -C "$dest" reset --hard "origin/${branch}" || true
      else git -C "$dest" pull --ff-only || true; fi
    else
      log "skip pull: ${name}"
    fi
  else
    log "clone: ${safe_url} -> ${dest} (branch='${branch:-default}')"
    if [ -n "$branch" ]; then git clone --branch "$branch" --single-branch "$url" "$dest" || { warn "clone failed: $spec"; return 0; }
    else git clone "$url" "$dest" || { warn "clone failed: $spec"; return 0; }
    fi
  fi
  chown -R "$PUID:$PGID" "$dest" || true
}

gitstrap_run(){
  GH_USERNAME="${GH_USERNAME:-}"; GH_PAT="${GH_PAT:-}"
  GIT_NAME="${GIT_NAME:-${GH_USERNAME:-}}"
  GIT_EMAIL="${GIT_EMAIL:-}"
  GH_REPOS="${GH_REPOS:-}"
  PULL_EXISTING_REPOS="${PULL_EXISTING_REPOS:-true}"

  # git defaults & identity
  git config --global init.defaultBranch main || true
  git config --global pull.ff only || true
  git config --global advice.detachedHead false || true
  git config --global --add safe.directory "*"
  git config --global user.name "${GIT_NAME:-gitstrap}" || true
  if [ -z "${GIT_EMAIL:-}" ]; then GIT_EMAIL="$(resolve_email || true)"; fi
  git config --global user.email "$GIT_EMAIL" || true
  log "identity: ${GIT_NAME:-} <${GIT_EMAIL:-}>"

  # ssh material
  umask 077
  [ -f "$PRIVATE_KEY_PATH" ] || { log "Generating SSH key"; ssh-keygen -t ed25519 -f "$PRIVATE_KEY_PATH" -N "" -C "${GIT_EMAIL:-git@github.com}"; chmod 600 "$PRIVATE_KEY_PATH"; chmod 644 "$PUBLIC_KEY_PATH"; }
  touch "$SSH_DIR/known_hosts"; chmod 644 "$SSH_DIR/known_hosts" || true
  if command -v ssh-keyscan >/dev/null 2>&1 && ! grep -q "^github.com" "$SSH_DIR/known_hosts" 2>/dev/null; then
    ssh-keyscan github.com >> "$SSH_DIR/known_hosts" 2>/dev/null || true
  fi
  git config --global core.sshCommand "ssh -i $PRIVATE_KEY_PATH -F /dev/null -o IdentitiesOnly=yes -o UserKnownHostsFile=$SSH_DIR/known_hosts -o StrictHostKeyChecking=accept-new"

  git_upload_key || true

  if [ -n "${GH_REPOS:-}" ]; then
    IFS=,; set -- $GH_REPOS; unset IFS
    for spec in "$@"; do clone_one "$spec" "$PULL_EXISTING_REPOS"; done
  else
    log "GH_REPOS empty; skip clone"
  fi
}

# =========================
# CLI implementation
# =========================
install_cli_shim(){
  mkdir -p /usr/local/bin
  cat >/usr/local/bin/gitstrap <<'EOF'
#!/usr/bin/env sh
set -eu
TARGET="/custom-cont-init.d/10-gitstrap.sh"
if [ -x "$TARGET" ]; then exec "$TARGET" "$@"; else exec sh "$TARGET" "$@"; fi
EOF
  chmod 755 /usr/local/bin/gitstrap
  # also expose version for external tools (optional)
  echo "${GITSTRAP_VERSION:-0.1.0}" >/etc/gitstrap-version 2>/dev/null || true
}

bootstrap_interactive(){
  # prompts fill envs if TTY
  GH_USERNAME="${GH_USERNAME:-$(prompt_def "GitHub username: " "")}"
  [ -n "${GH_PAT:-}" ] || GH_PAT="$(prompt_secret "GitHub PAT (classic: user:email, admin:public_key): ")"
  GIT_NAME="$(prompt_def "Git name [${GIT_NAME:-$GH_USERNAME}]: " "${GIT_NAME:-$GH_USERNAME}")"
  GIT_EMAIL="$(prompt_def "Git email (blank=auto): " "${GIT_EMAIL:-}")"
  GH_REPOS="$(prompt_def "Repos (comma-separated owner/repo[#branch]): " "${GH_REPOS:-}")"
  PULL_EXISTING_REPOS="$(yn_to_bool "$(prompt_def "Pull existing repos? [Y/n]: " "y")")"

  [ -n "${GH_USERNAME:-}" ] || { echo "GH_USERNAME required." >&2; exit 2; }
  [ -n "${GH_PAT:-}" ]     || { echo "GH_PAT required." >&2; exit 2; }

  export GH_USERNAME GH_PAT GIT_NAME GIT_EMAIL GH_REPOS PULL_EXISTING_REPOS
  gitstrap_run
  log "bootstrap complete"
}

bootstrap_env_only(){
  [ -n "${GH_USERNAME:-}" ] || { echo "GH_USERNAME required (env)." >&2; exit 2; }
  [ -n "${GH_PAT:-}" ]     || { echo "GH_PAT required (env)." >&2; exit 2; }
  gitstrap_run
  log "bootstrap complete (env)"
}

cli_entry(){
  # no args → default to bootstrap (interactive if TTY, else env-only)
  if [ $# -eq 0 ]; then
    if is_tty; then bootstrap_interactive; else bootstrap_env_only; fi
    exit 0
  fi

  case "$1" in
    -h|--help)    print_help; exit 0;;
    -v|--version) print_version; exit 0;;
    --env)        bootstrap_env_only; exit 0;;
    passwd)       password_change_interactive; exit 0;;
    *)            # allow flags like --user/--pat in future; for now just help
                  warn "Unknown argument: $1"; print_help; exit 1;;
  esac
}

# =========================
# Autorun on container start
# =========================
autorun_env_if_present(){
  if [ -n "${GH_USERNAME:-}" ] && [ -n "${GH_PAT:-}" ] && [ ! -f "$LOCK_FILE" ]; then
    : > "$LOCK_FILE" || true
    log "env present and no lock → running bootstrap"
    gitstrap_run || true
  else
    [ -f "$LOCK_FILE" ] && log "init lock present → skip duplicate autorun"
    { [ -z "${GH_USERNAME:-}" ] || [ -z "${GH_PAT:-}" ]; } && log "GH_USERNAME/GH_PAT missing → no autorun"
  fi
}

# =========================
# Entry point (init or CLI)
# =========================
case "${1:-init}" in
  init)
    install_restart_gate
    install_cli_shim
    init_default_password
    autorun_env_if_present
    log "Gitstrap initialized. Use: gitstrap -h"
    ;;
  -h|--help|--env|passwd|-v|--version)
    cli_entry "$@"
    ;;
  *)
    # If called with arbitrary args by user, treat as CLI
    if [ $# -gt 0 ]; then
      cli_entry "$@"
    else
      # Fallback: init
      install_restart_gate
      install_cli_shim
      init_default_password
      autorun_env_if_present
      log "Gitstrap initialized. Use: gitstrap -h"
    fi
    ;;
esac
