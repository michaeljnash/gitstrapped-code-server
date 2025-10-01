#!/usr/bin/env sh
# codestrap — bootstrap GitHub + manage code-server auth (CLI-first)
set -eu

VERSION="${CODESTRAP_VERSION:-0.3.8}"

# ===== context-aware logging =====
PROMPT_TAG=""     # shown before interactive questions
CTX_TAG=""        # shown before status/warn/error lines

has_tty(){ [ -c /dev/tty ] && [ -r /dev/tty ] && [ -w /dev/tty ]; }
is_tty(){ [ -t 0 ] && [ -t 1 ] || has_tty; }

red(){ is_tty && printf "\033[31m%s\033[0m" "$1" || printf "%s" "$1"; }
ylw(){ is_tty && printf "\033[33m%s\033[0m" "$1" || printf "%s" "$1"; }

log(){  printf "%s %s\n" "${CTX_TAG:-[codestrap]}" "$*"; }
warn(){ printf "%s\n" "$(ylw "${CTX_TAG:-[codestrap]}[WARN] $*")" >&2; }
err(){  printf "%s\n" "$(red "${CTX_TAG:-[codestrap]}[ERROR] $*")" >&2; }

# ----- run-mode + generic helpers -----
# Will be set in entrypoint: RUN_MODE=init|cli  (default cli for safety)
RUN_MODE="${RUN_MODE:-cli}"

# Run a step safely: in CLI, exit on failure; in INIT, log + continue.
safe_run(){ # usage: safe_run "<ctx-tag>" <command> [args...]
  _ctx="$1"; shift
  CTX_TAG="$_ctx"
  if ! "$@"; then
    if [ "$RUN_MODE" = "cli" ]; then
      err "step failed: $*"
      CTX_TAG=""
      exit 1
    else
      err "step failed (continuing): $*"
      CTX_TAG=""
      return 0
    fi
  fi
  CTX_TAG=""
}

# Use this *inside* functions when you detect a condition that should
# abort the current function:
#  - CLI: print error and exit 1
#  - INIT: print error and return 0 (so caller continues)
abort_or_continue(){ # usage: abort_or_continue "<ctx-tag>" "message..."
  _ctx="${1:-[codestrap]}"; shift || true
  _msg="$*"
  CTX_TAG="$_ctx"
  if [ "$RUN_MODE" = "cli" ]; then
    err "$_msg"
    CTX_TAG=""
    exit 1
  else
    err "$_msg"
    CTX_TAG=""
    return 0
  fi
}

redact(){ echo "$1" | sed 's/[A-Za-z0-9_\-]\{12,\}/***REDACTED***/g'; }
ensure_dir(){ mkdir -p "$1" 2>/dev/null || true; chown -R "${PUID:-1000}:${PGID:-1000}" "$1" 2>/dev/null || true; }

# ===== prompts (prefix each with PROMPT_TAG) =====
read_line(){ if has_tty; then IFS= read -r _l </dev/tty || true; else IFS= read -r _l || true; fi; printf "%s" "${_l:-}"; }
prompt(){ msg="$1"; if has_tty; then printf "%s%s" "$PROMPT_TAG" "$msg" >/dev/tty; else printf "%s%s" "$PROMPT_TAG" "$msg"; fi; read_line; }
prompt_def(){ v="$(prompt "$1")"; [ -n "$v" ] && printf "%s" "$v" || printf "%s" "$2"; }
prompt_secret(){
  if has_tty; then
    printf "%s%s" "$PROMPT_TAG" "$1" >/dev/tty
    stty -echo </dev/tty >/dev/tty 2>/dev/null || true
    IFS= read -r s </dev/tty || true
    stty echo </dev/tty >/dev/tty 2>/dev/null || true
    printf "\n" >/dev/tty 2>/dev/null || true
  else
    printf "%s%s" "$PROMPT_TAG" "$1"; IFS= read -r s || true
  fi; printf "%s" "${s:-}"
}
yn_to_bool(){ case "$(printf "%s" "$1" | tr '[:upper:]' '[:lower:]')" in y|yes|t|true|1) echo "true";; *) echo "false";; esac; }
normalize_bool(){ v="${1:-true}"; [ "$(printf '%s' "$v" | cut -c1 | tr '[:upper:]' '[:lower:]')" = "f" ] && echo false || echo true; }
prompt_yn(){ q="$1"; def="${2:-y}"; ans="$(prompt_def "$q " "$def")"; yn_to_bool "$ans"; }

print_help(){
cat <<'HLP'
codestrap — bootstrap GitHub + manage code-server auth

Usage (subcommands):
  codestrap                      # Interactive hub: ask GitHub? Config? Change password?
  codestrap github [flags...]    # GitHub bootstrap (interactive/flags/--auto)
  codestrap config [flags...]    # Config hub (interactive + flags to skip prompts)
  codestrap extensions [flags...]# Install/update/uninstall extensions from extensions.json
  codestrap passwd               # Interactive password change (secure prompts)
  codestrap -h | --help          # Help
  codestrap -v | --version       # Version

NOTE: For any flag that expects a boolean or scope value, you can use the first letter:
  true/false → t/f, yes/no → y/n, all/missing → a/m.

Flags for 'codestrap github' (hyphenated only; envs shown at right):
  -u, --username <val>           → GITHUB_USERNAME
  -t, --token <val>              → GITHUB_TOKEN   (classic; scopes: user:email, admin:public_key)
  -n, --name <val>               → GITHUB_NAME
  -e, --email <val>              → GITHUB_EMAIL
  -r, --repos "<specs>"          → GITHUB_REPOS   (owner/repo, owner/repo#branch, https://github.com/owner/repo)
  -p, --pull <true|false>        → GITHUB_PULL    (default: true)
  -a, --auto                     Use environment variables only (no prompts)

Env-only (no flags):
  WORKSPACE_DIR (default: /config/workspace)
  REPOS_SUBDIR  (default: repos; RELATIVE to WORKSPACE_DIR)

Flags for 'codestrap config' (booleans; supply only the ones you want to skip prompts for):
  -s, --settings <true|false>    Merge strapped settings.json into user settings.json
  -k, --keybindings <true|false> Merge strapped keybindings.json into user keybindings.json
  -e, --extensions <true|false>  Merge strapped extensions.json into user extensions.json
                                 (Interactive default: ask; Non-interactive default: true)

Flags for 'codestrap extensions':
  -i, --install <all|missing|a|m>     Install/update extensions from merged extensions.json:
                                      all/a     → install missing + update already-installed to latest
                                      missing/m → install only those not yet installed
  -u, --uninstall <all|missing|a|m>   Uninstall extensions:
                                      all/a     → uninstall *all* installed extensions
                                      missing/m → uninstall extensions NOT in recommendations (cleanup)
  (No flags) → interactive: choose install or uninstall, then scope.

Env vars (init-time automation; uninstall runs BEFORE install):
  EXTENSIONS_UNINSTALL=<all|a|missing|m|none>   # default none
  EXTENSIONS_INSTALL=<all|a|missing|m|none>     # default none

Interactive tip (github):
  At any 'github' prompt you can type -a or --auto to use the corresponding environment variable (the hint appears only if that env var is set).

Examples:
  codestrap
  codestrap github -u alice -t ghp_xxx -r "alice/app#main, org/infra"
  codestrap config -s t -k f -e t
  codestrap extensions -i all
  codestrap extensions -i m -u m          # sync to recommendations
  codestrap passwd
HLP
}

print_version(){ echo "codestrap ${VERSION}"; }

# ===== paths / state =====
export HOME="${HOME:-/config}"
PUID="${PUID:-1000}"; PGID="${PGID:-1000}"

STATE_DIR="$HOME/.codestrap"; ensure_dir "$STATE_DIR"
LOCK_DIR="/run/codestrap";    ensure_dir "$LOCK_DIR"
LOCK_FILE="$LOCK_DIR/init-codestrap.lock"

PASS_HASH_PATH="${FILE__HASHED_PASSWORD:-$STATE_DIR/password.hash}"
FIRSTBOOT_MARKER="$STATE_DIR/.firstboot-auth-restart"

# Workspace + repos path joining (REPOS_SUBDIR always relative)
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/workspace}"
WORKSPACE_DIR="$(printf '%s' "$WORKSPACE_DIR" | sed 's:/*$::')"
ensure_dir "$WORKSPACE_DIR"

REPOS_SUBDIR="${REPOS_SUBDIR:-repos}"
REPOS_SUBDIR="$(printf '%s' "$REPOS_SUBDIR" | sed 's:^/*::; s:/*$::')"

if [ -n "$REPOS_SUBDIR" ]; then
  BASE="${WORKSPACE_DIR}/${REPOS_SUBDIR}"
else
  BASE="${WORKSPACE_DIR}"
fi
ensure_dir "$BASE"

SSH_DIR="$HOME/.ssh"; ensure_dir "$SSH_DIR"
KEY_NAME="id_ed25519"; PRIVATE_KEY_PATH="$SSH_DIR/$KEY_NAME"; PUBLIC_KEY_PATH="$SSH_DIR/${KEY_NAME}.pub"

# VS Code settings paths
USER_DIR="$HOME/data/User"; ensure_dir "$USER_DIR"
SETTINGS_PATH="$USER_DIR/settings.json"
TASKS_PATH="$USER_DIR/tasks.json"
KEYB_PATH="$USER_DIR/keybindings.json"
EXT_PATH="$USER_DIR/extensions.json"

REPO_SETTINGS_SRC="$HOME/codestrap/settings.json"
REPO_KEYB_SRC="$HOME/codestrap/keybindings.json"
REPO_EXT_SRC="$HOME/codestrap/extensions.json"
MANAGED_KEYS_FILE="$STATE_DIR/managed-settings-keys.json"

# Track origins for nicer errors
ORIGIN_GITHUB_USERNAME="${ORIGIN_GITHUB_USERNAME:-}"
ORIGIN_GITHUB_TOKEN="${ORIGIN_GITHUB_TOKEN:-}"

# ===== external preserve store =====
PRESERVE_MAIN="$HOME/codestrap/codestrap_preserve.json"
PRESERVE_LINK="$USER_DIR/codestrap_preserve.json"

read_preserve_array_json(){ # usage: read_preserve_array_json settings|keybindings
  kind="$1"
  [ -f "$PRESERVE_MAIN" ] || { echo '[]'; return 0; }
  if jq -e . "$PRESERVE_MAIN" >/dev/null 2>&1; then
    jq -c --arg k "$kind" '.[$k] // []' "$PRESERVE_MAIN" 2>/dev/null || echo '[]'
  else
    echo '[]'
  fi
}

merge_preserve_files_union(){
  # If both a user copy and a main copy exist (and are valid JSON), union arrays per key.
  u="$1"; m="$2"; tmp="$(mktemp)"
  if jq -e . "$u" >/dev/null 2>&1 && jq -e . "$m" >/dev/null 2>&1; then
    jq -n --slurpfile U "$u" --slurpfile M "$m" '
      def keys_all: ([$U[0]|keys[], $M[0]|keys[]] | add | unique);
      def arr(x): if (x|type)=="array" then x else [] end;
      reduce (keys_all[]) as $k ({}; .[$k] = ( (arr($U[0][$k]) + arr($M[0][$k])) | unique ))
    ' >"$tmp" || cp -f "$m" "$tmp"
    mv -f "$tmp" "$m"
  else
    # prefer the one that parses; otherwise create empty
    if jq -e . "$u" >/dev/null 2>&1; then cp -f "$u" "$m"
    elif jq -e . "$m" >/dev/null 2>&1; then : # keep main
    else echo '{}' >"$m"
    fi
  fi
  rm -f "$tmp" 2>/dev/null || true
}

ensure_preserve_store(){
  ensure_dir "$(dirname "$PRESERVE_MAIN")"
  ensure_dir "$USER_DIR"

  # If neither exists, seed an empty object
  if [ ! -e "$PRESERVE_MAIN" ] && [ ! -e "$PRESERVE_LINK" ]; then
    printf '%s\n' '{ "settings": [], "keybindings": [] }' >"$PRESERVE_MAIN"
    chown "${PUID}:${PGID}" "$PRESERVE_MAIN" 2>/dev/null || true
  fi

  # If a regular file exists in the user dir, migrate/merge it into main then remove it
  if [ -e "$PRESERVE_LINK" ] && [ ! -L "$PRESERVE_LINK" ]; then
    [ -e "$PRESERVE_MAIN" ] || printf '%s\n' '{}' >"$PRESERVE_MAIN"
    merge_preserve_files_union "$PRESERVE_LINK" "$PRESERVE_MAIN"
    rm -f "$PRESERVE_LINK" 2>/dev/null || true
  fi

  # Create/refresh link from user dir → main
  if [ -L "$PRESERVE_LINK" ]; then
    # Already a symlink: if it points to the right place, keep; else replace.
    tgt="$(readlink "$PRESERVE_LINK" || true)"
    case "$tgt" in
      /*) abs="$tgt" ;;
      *)  abs="$(cd "$(dirname "$PRESERVE_LINK")" 2>/dev/null && printf "%s/%s" "$(pwd)" "$tgt")" ;;
    esac
    if [ "$abs" != "$PRESERVE_MAIN" ]; then
      rm -f "$PRESERVE_LINK" 2>/dev/null || true
      ln -s "$PRESERVE_MAIN" "$PRESERVE_LINK" 2>/dev/null || true
    fi
  elif [ -e "$PRESERVE_LINK" ]; then
    # A non-symlink file existed; we've migrated it above. Do nothing further.
    :
  else
    # Link path does not exist — try symlink first; if that fails (FS limitation), copy.
    if ! ln -s "$PRESERVE_MAIN" "$PRESERVE_LINK" 2>/dev/null; then
      # Avoid copying a file onto itself
      if [ ! "$PRESERVE_MAIN" -ef "$PRESERVE_LINK" ]; then
        cp -f "$PRESERVE_MAIN" "$PRESERVE_LINK"
      fi
    fi
  fi

  # Chown link itself (if supported) or the file it points to
  chown -h "${PUID}:${PGID}" "$PRESERVE_LINK" 2>/dev/null || chown "${PUID}:${PGID}" "$PRESERVE_LINK" 2>/dev/null || true
}

# ===== root guard =====
require_root(){ if [ "$(id -u)" != "0" ]; then warn "not root; skipping system install step"; return 1; fi; return 0; }

# ===== restart gate (root-only) =====
install_restart_gate(){
  require_root || return 0
  NODE_BIN=""
  for p in /usr/local/bin/node /usr/bin/node /app/code-server/lib/node /usr/lib/code-server/lib/node; do [ -x "$p" ] && { NODE_BIN="$p"; break; }; done
  [ -n "$NODE_BIN" ] || { warn "Node not found; restart gate disabled"; return 0; }
  mkdir -p /usr/local/bin
  cat >/usr/local/bin/restartgate.js <<'EOF'
const http = require('http'); const { exec } = require('child_process');
const PORT = 9000, HOST = '127.0.0.1';
function supervisedRestart(){
  const cmd = "sh -c 'for i in 1 2 3 4 5; do [ -p /run/s6/scan-control ] && break; sleep 0.4; done; s6-svscanctl -t /run/s6 >/dev/null 2>&1 || kill -TERM 1 >/dev/null 2>&1'";
  exec(cmd, () => {});
}
http.createServer((req,res)=>{
  const url=(req.url||'/').split('?')[0];
  if(url==='/health'){ res.writeHead(200,{'Content-Type':'text/plain'}).end('OK'); return; }
  if(url==='/restart'){ res.writeHead(200,{'Content-Type':'text/plain'}).end('OK'); supervisedRestart(); return; }
  res.writeHead(200,{'Content-Type':'text/plain'}).end('OK');
}).listen(PORT, HOST, ()=>console.log(`[restartgate] ${HOST}:${PORT}`));
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
  printf '%s\n' '#!/usr/bin/env sh' 'exit 0' >/etc/services.d/restartgate/finish && chmod +x /etc/services.d/restartgate/finish
  log "installed restart gate service"
}
trigger_restart_gate(){ command -v curl >/dev/null 2>&1 && curl -fsS --max-time 3 "http://127.0.0.1:9000/restart" >/dev/null 2>&1 || true; }

# ===== first-boot default password =====
init_default_password(){
  DEFAULT_PASSWORD="${DEFAULT_PASSWORD:-}"
  [ -n "$DEFAULT_PASSWORD" ] || { log "DEFAULT_PASSWORD not set; skipping default hash"; return 0; }
  [ -s "$PASS_HASH_PATH" ] && { log "hash exists; leaving as-is"; return 0; }
  tries=0; until command -v argon2 >/dev/null 2>&1; do tries=$((tries+1)); [ $tries -ge 20 ] && { warn "argon2 not found"; return 0; }; sleep 1; done
  ensure_dir "$(dirname "$PASS_HASH_PATH")"
  salt="$(head -c16 /dev/urandom | base64)"
  hash="$(printf '%s' "$DEFAULT_PASSWORD" | argon2 "$salt" -id -e)"
  printf '%s' "$hash" > "$PASS_HASH_PATH"; chmod 644 "$PASS_HASH_PATH" || true; chown "${PUID}:${PGID}" "$PASS_HASH_PATH" 2>/dev/null || true
  : > "$FIRSTBOOT_MARKER"; log "wrote initial password hash"
}

# ===== helpers for interactive -a/--auto =====
env_hint(){ eval "tmp=\${$1:-}"; [ -n "${tmp:-}" ] && printf " (type -a/--auto to use env %s)" "$1" || true; }
read_or_env(){ hint="$(env_hint "$2")"; val="$(prompt_def "$1$hint: " "$3")"; case "$val" in -a|--auto) eval "tmp=\${$2:-}"; [ -z "${tmp:-}" ] && { err "$2 requested via --auto at prompt, but $2 is not set."; exit 2; }; printf "%s" "$tmp";; *) printf "%s" "$val";; esac; }
read_secret_or_env(){ hint="$(env_hint "$2")"; val="$(prompt_secret "$1$hint: ")"; case "$val" in -a|--auto) eval "tmp=\${$2:-}"; [ -z "${tmp:-}" ] && { err "$2 requested via --auto at prompt, but $2 is not set."; exit 2; }; printf "%s" "$tmp";; *) printf "%s" "$val";; esac; }
read_bool_or_env(){ def="${3:-y}"; hint="$(env_hint "$2")"; val="$(prompt_def "$1$hint " "$def")"; case "$val" in -a|--auto) eval "tmp=\${$2:-}"; [ -z "${tmp:-}" ] && { err "$2 requested via --auto at prompt, but $2 is not set."; exit 2; }; printf "%s" "$(normalize_bool "$tmp")";; *) printf "%s" "$(yn_to_bool "$val")";; esac; }

# ===== GitHub validation (fatal on failure) =====
validate_github_username(){
  [ -n "${GITHUB_USERNAME:-}" ] || return 0
  code="$(curl -s -o /dev/null -w "%{http_code}" -H "Accept: application/vnd.github+json" "https://api.github.com/users/${GITHUB_USERNAME}" || echo "000")"
  if [ "$code" = "404" ]; then
    src="${ORIGIN_GITHUB_USERNAME:-env GITHUB_USERNAME}"
    err "GitHub username '${GITHUB_USERNAME}' appears invalid (HTTP 404). Check ${src}."
    return 1
  elif [ "$code" != "200" ]; then
    err "Could not verify GitHub username '${GITHUB_USERNAME}' (HTTP $code)."
    return 1
  fi
}

validate_github_token(){
  [ -n "${GITHUB_TOKEN:-}" ] || return 0
  code="$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: codestrap" \
    https://api.github.com/user || echo "000")"
  src="${ORIGIN_GITHUB_TOKEN:-env GITHUB_TOKEN}"
  if [ "$code" = "401" ]; then
    err "Provided GITHUB_TOKEN (${src}) is invalid or expired (HTTP 401). Please provide a valid classic token with scopes: user:email, admin:public_key."
    return 1
  elif [ "$code" = "403" ]; then
    err "Provided GITHUB_TOKEN (${src}) is not authorized (HTTP 403). It may be missing required scopes: user:email, admin:public_key."
    return 1
  elif [ "$code" != "200" ]; then
    err "Could not verify GITHUB_TOKEN (${src}) (HTTP $code)."
    return 1
  fi
  headers="$(curl -fsS -D - -o /dev/null \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: codestrap" \
    https://api.github.com/user 2>/dev/null || true)"
  scopes="$(printf "%s" "$headers" | awk -F': ' '/^[Xx]-[Oo]Auth-[Ss]copes:/ {gsub(/\r/,"",$2); print $2}')"
  if [ -n "$scopes" ]; then
    echo "$scopes" | grep -q 'admin:public_key' || warn "$(ylw "GITHUB_TOKEN may be missing 'admin:public_key' (needed to upload SSH key). Current scopes: $scopes")"
    echo "$scopes" | grep -q 'user:email'       || warn "$(ylw "GITHUB_TOKEN may be missing 'user:email' (needed to resolve your primary email). Current scopes: $scopes")"
  fi
}

# ===== password change =====
password_change_interactive(){
  command -v argon2 >/dev/null 2>&1 || { CTX_TAG="[Change password]"; err "argon2 not found."; CTX_TAG=""; return 1; }

  _OLD_PROMPT_TAG="$PROMPT_TAG"
  _OLD_CTX_TAG="$CTX_TAG"
  PROMPT_TAG="[Change password] ? "
  CTX_TAG="[Change password]"

  NEW="$(prompt_secret "New code-server password: ")"
  CONF="$(prompt_secret "Confirm password: ")"

  [ -n "$NEW" ]  || { err "password required!";  PROMPT_TAG="$_OLD_PROMPT_TAG"; CTX_TAG="$_OLD_CTX_TAG"; return 1; }
  [ -n "$CONF" ] || { err "confirmation required!"; PROMPT_TAG="$_OLD_PROMPT_TAG"; CTX_TAG="$_OLD_CTX_TAG"; return 1; }
  [ "$NEW" = "$CONF" ] || { err "passwords do not match!"; PROMPT_TAG="$_OLD_PROMPT_TAG"; CTX_TAG="$_OLD_CTX_TAG"; return 1; }
  [ ${#NEW} -ge 8 ] || { err "minimum length 8!"; PROMPT_TAG="$_OLD_PROMPT_TAG"; CTX_TAG="$_OLD_CTX_TAG"; return 1; }

  salt="$(head -c16 /dev/urandom | base64)"
  hash="$(printf '%s' "$NEW" | argon2 "$salt" -id -e)"
  printf '%s' "$hash" > "$PASS_HASH_PATH"; chmod 644 "$PASS_HASH_PATH" || true; chown "${PUID}:${PGID}" "$PASS_HASH_PATH" 2>/dev/null || true
  printf "\n\033[1;33m*** CODE-SERVER PASSWORD CHANGED ***\n*** REFRESH PAGE TO LOGIN ***\033[0m\n\n"
  trigger_restart_gate

  PROMPT_TAG="$_OLD_PROMPT_TAG"
  CTX_TAG="$_OLD_CTX_TAG"
}

# ===== github bootstrap internals =====
resolve_email(){
  GITHUB_USERNAME="${GITHUB_USERNAME:-}"; GITHUB_TOKEN="${GITHUB_TOKEN:-}"
  [ -n "$GITHUB_TOKEN" ] || { echo "${GITHUB_USERNAME:-unknown}@users.noreply.github.com"; return; }
  EMAILS="$(curl -fsS -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" https://api.github.com/user/emails || true)"
  PRIMARY="$(printf "%s" "$EMAILS" | awk -F\" '/"email":/ {e=$4} /"primary": *true/ {print e; exit}')"
  [ -n "${PRIMARY:-}" ] && { echo "$PRIMARY"; return; }
  VERIFIED="$(printf "%s" "$EMAILS" | awk -F\" '/"email":/ {e=$4} /"verified": *true/ {print e; exit}')"
  [ -n "${VERIFIED:-}" ] && { echo "$VERIFIED"; return; }
  PUB_JSON="$(curl -fsS -H "Accept: application/vnd.github+json" "https://api.github.com/users/${GITHUB_USERNAME}" || true)"
  PUB_EMAIL="$(printf "%s" "$PUB_JSON" | awk -F\" '/"email":/ {print $4; exit}')"
  [ -n "${PUB_EMAIL:-}" ] && [ "$PUB_EMAIL" != "null" ] && { echo "$PUB_EMAIL"; return; }
  echo "${GITHUB_USERNAME:-unknown}@users.noreply.github.com"
}
git_upload_key(){
  GITHUB_TOKEN="${GITHUB_TOKEN:-}"; GH_KEY_TITLE="${GH_KEY_TITLE:-codestrapped-code-server SSH Key}"
  [ -n "$GITHUB_TOKEN" ] || { warn "GITHUB_TOKEN empty; cannot upload SSH key"; return 0; }
  LOCAL_KEY="$(awk '{print $1" "$2}' "$PUBLIC_KEY_PATH")"
  KEYS_JSON="$(curl -fsS -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" https://api.github.com/user/keys || true)"
  echo "$KEYS_JSON" | grep -q "\"key\": *\"$LOCAL_KEY\"" && { log "SSH key already on GitHub"; return 0; }
  RESP="$(curl -fsS -X POST -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" -d "{\"title\":\"$GH_KEY_TITLE\",\"key\":\"$LOCAL_KEY\"}" https://api.github.com/user/keys || true)"
  echo "$RESP" | grep -q '"id"' && log "SSH key added" || warn "Key upload failed: $(redact "$RESP")"
}
clone_one(){
  spec="$1"; PULL="${2:-true}"
  spec="$(echo "$spec" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"; [ -n "$spec" ] || return 0
  repo="$spec"; branch=""
  case "$spec" in *'#'*) branch="${spec#*#}"; repo="${spec%%#*}";; esac
  case "$repo" in
    *"git@github.com:"*) url="$repo"; name="$(basename "$repo" .git)";;
    http*://github.com/*|ssh://git@github.com/*) name="$(basename "$repo" .git)"; owner_repo="$(echo "$repo" | sed -E 's#^https?://github\.com/##; s#^ssh://git@github\.com/##')"; owner_repo="${owner_repo%.git}"; url="git@github.com:${owner_repo}.git";;
    */*) name="$(basename "$repo")"; url="git@github.com:${repo}.git";;
    *) err "Invalid repo spec: '$spec'. Use owner/repo, owner/repo#branch, or a GitHub URL."; return 1;;
  esac
  dest="${BASE}/${name}"
  safe_url="$(echo "$url" | sed -E 's#(git@github\.com:).*#\1***.git#')"
  if [ -d "$dest/.git" ]; then
    if [ "$(normalize_bool "$PULL")" = "true" ] && command -v git >/dev/null 2>&1; then
      log "pull: ${name}"
      git -C "$dest" fetch --all -p || warn "fetch failed for ${name}"
      if [ -n "$branch" ]; then
        git -C "$dest" checkout "$branch" || warn "checkout ${branch} failed for ${name}"
        git -C "$dest" reset --hard "origin/${branch}" || warn "hard reset origin/${branch} failed for ${name}"
      else
        git -C "$dest" pull --ff-only || warn "pull --ff-only failed for ${name}"
      fi
    else
      log "skip pull: ${name}"
    fi
  else
    log "clone: ${safe_url} -> ${dest} (branch='${branch:-default}')"
    if [ -n "$branch" ]; then
      git clone --branch "$branch" --single-branch "$url" "$dest" || { err "Clone failed for '$spec'"; return 1; }
    else
      git clone "$url" "$dest" || { err "Clone failed for '$spec'"; return 1; }
    fi
  fi
  chown -R "$PUID:$PGID" "$dest" || true
}

codestrap_run(){
  GITHUB_USERNAME="${GITHUB_USERNAME:-}"; GITHUB_TOKEN="${GITHUB_TOKEN:-}"
  GITHUB_NAME="${GITHUB_NAME:-${GITHUB_USERNAME:-}}"; GITHUB_EMAIL="${GITHUB_EMAIL:-}"
  GITHUB_REPOS="${GITHUB_REPOS:-}"; GITHUB_PULL="${GITHUB_PULL:-true}"

  if ! validate_github_username; then
    abort_or_continue "[Bootstrap GitHub]" "GitHub username validation failed."
    return 0
  fi
  if ! validate_github_token; then
    abort_or_continue "[Bootstrap GitHub]" "GitHub token validation failed."
    return 0
  fi

  git config --global init.defaultBranch main || true
  git config --global pull.ff only || true
  git config --global advice.detachedHead false || true
  git config --global --add safe.directory "*"
  git config --global user.name "${GITHUB_NAME:-codestrap}" || true
  if [ -z "${GITHUB_EMAIL:-}" ]; then GITHUB_EMAIL="$(resolve_email || true)"; fi
  git config --global user.email "$GITHUB_EMAIL" || true
  log "identity: ${GITHUB_NAME:-} <${GITHUB_EMAIL:-}>"
  umask 077
  [ -f "$PRIVATE_KEY_PATH" ] || { log "Generating SSH key"; ssh-keygen -t ed25519 -f "$PRIVATE_KEY_PATH" -N "" -C "${GITHUB_EMAIL:-git@github.com}"; chmod 600 "$PRIVATE_KEY_PATH"; chmod 644 "$PUBLIC_KEY_PATH"; }
  touch "$SSH_DIR/known_hosts"; chmod 644 "$SSH_DIR/known_hosts" || true
  if command -v ssh-keyscan >/dev/null 2>&1 && ! grep -q "^github.com" "$SSH_DIR/known_hosts" 2>/dev/null; then ssh-keyscan github.com >> "$SSH_DIR/known_hosts" 2>/dev/null || true; fi
  git config --global core.sshCommand "ssh -i $PRIVATE_KEY_PATH -F /dev/null -o IdentitiesOnly=yes -o UserKnownHostsFile=$SSH_DIR/known_hosts -o StrictHostKeyChecking=accept-new"
  git_upload_key || true

  if [ -n "${GITHUB_REPOS:-}" ]; then
    IFS=,; set -- $GITHUB_REPOS; unset IFS
    CLONE_ERRORS=0
    for spec in "$@"; do
      if ! clone_one "$spec" "$GITHUB_PULL"; then
        CLONE_ERRORS=$((CLONE_ERRORS+1))
      fi
    done
    if [ "$CLONE_ERRORS" -gt 0 ]; then
      abort_or_continue "[Bootstrap GitHub]" "One or more repositories failed to clone ($CLONE_ERRORS)."
      return 0
    fi
  else
    log "GITHUB_REPOS empty; skip clone"
  fi
}

# ===== JSONC → JSON (comments only) =====
strip_jsonc_to_json(){ sed -e 's://[^\r\n]*$::' -e '/\/\*/,/\*\//d' "$1"; }

write_inplace(){
  # usage: write_inplace <tmp_src> <dest_path>
  tmp="$1"; dest="$2"
  dest_dir="$(dirname "$dest")"; mkdir -p "$dest_dir" || true
  if [ -f "$dest" ]; then
    # Overwrite contents without replacing the inode (keeps watchers alive)
    cat "$tmp" > "$dest"
  else
    # First-time create (sets perms/owner once)
    install -m 644 -D "$tmp" "$dest"
    chown "${PUID:-1000}:${PGID:-1000}" "$dest" 2>/dev/null || true
  fi
}

# ===== top-of-file error banner =====
_banner_strip_first_if_error(){
  # strip the first line if it is our banner
  awk 'NR==1 && $0 ~ /^\/\/ CODESTRAP-ERROR:/ { next } { print }'
}

put_error_banner_with_hint(){ # usage: put_error_banner_with_hint <file> "<base-msg>" "<hint>"
  file="$1"; shift; base="$1"; shift; hint="$*"
  ensure_dir "$(dirname "$file")"
  ts="$(date -u '+%Y-%m-%d %H:%M:%SZ')"
  tmp="$(mktemp)"
  {
    printf '%s\n' "// CODESTRAP-ERROR: ${ts} - ${base} ***${hint}***"
    [ -f "$file" ] && _banner_strip_first_if_error <"$file"
  } >"$tmp"
  write_inplace "$tmp" "$file"
  rm -f "$tmp" 2>/dev/null || true
}

put_error_banner_this(){ # usage: put_error_banner_this <file> "<base-msg>"
  put_error_banner_with_hint "$1" "$2" "Fix errors in this file and run \`codestrap config\` again!"
}

put_error_banner_repo(){ # usage: put_error_banner_repo <file> "<base-msg>" "<repo-kind>" "<repo-abs-path>"
  # repo-kind examples: "repo settings.json", "repo keybindings.json", "repo extensions.json"
  # repo-abs-path is the actual $REPO_*_SRC path we tried to read (already absolute via $HOME)
  put_error_banner_with_hint "$1" "$2" "Fix errors in ${3} file or ${4} file and run \`codestrap config\` again!"
}

clear_error_banner(){ # usage: clear_error_banner <file>
  file="$1"
  [ -f "$file" ] || return 0
  tmp="$(mktemp)"
  _banner_strip_first_if_error <"$file" >"$tmp"
  write_inplace "$tmp" "$file"
  rm -f "$tmp" 2>/dev/null || true
}

# ===== settings.json merge =====
merge_codestrap_settings(){
  [ -f "$REPO_SETTINGS_SRC" ] || { log "no repo settings.json; skipping settings merge"; return 0; }
  command -v jq >/dev/null 2>&1 || { warn "jq not available; skipping settings merge"; return 0; }

  ensure_dir "$USER_DIR"; ensure_dir "$STATE_DIR"

  # --- collect inline-preserve keys from existing user file (same-line //preserve) ---
  tmp_preserve_keys="$(mktemp)"
  : >"$tmp_preserve_keys"
  if [ -f "$SETTINGS_PATH" ]; then
    _banner_strip_first_if_error <"$SETTINGS_PATH" | awk '
      # Lines whose last token is //preserve (allow spaces before it)
      /\/\/[[:space:]]*preserve[[:space:]]*$/ {
        line = $0
        # drop the trailing //preserve so it doesn’t interfere with matching
        sub(/\/\/[[:space:]]*preserve[[:space:]]*$/, "", line)
        # Find top-level   "key"  :
        if (match(line, /^[[:space:]]*\"[^\"]+\"[[:space:]]*:/)) {
          ms = substr(line, RSTART, RLENGTH)
          q1 = index(ms, "\"")
          if (q1 > 0) {
            rest = substr(ms, q1 + 1)
            q2 = index(rest, "\"")
            if (q2 > 1) {
              key = substr(rest, 1, q2 - 1)
              print key
            }
          }
        }
      }
    ' | awk 'NF' | awk '!seen[$0]++' >"$tmp_preserve_keys"
  fi

  # ---- Load USER (allow comments only) ----
  tmp_user_json="$(mktemp)"
  if [ -f "$SETTINGS_PATH" ]; then
    if jq -e . "$SETTINGS_PATH" >/dev/null 2>&1; then
      cp "$SETTINGS_PATH" "$tmp_user_json"
    else
      strip_jsonc_to_json "$SETTINGS_PATH" >"$tmp_user_json" || true
      if ! jq -e . "$tmp_user_json" >/dev/null 2>&1; then
        rm -f "$tmp_user_json" 2>/dev/null || true
        put_error_banner_this "$SETTINGS_PATH" "user settings.json is malformed; skipped merge to avoid data loss."
        abort_or_continue "[Bootstrap config]" "user settings.json is malformed; skipped merge to avoid data loss."
        rm -f "$tmp_preserve_keys" 2>/dev/null || true
        return 0
      fi
    fi
  else
    printf '{}\n' >"$tmp_user_json"
  fi

  # ---- Load REPO (allow comments only) ----
  tmp_repo_json="$(mktemp)"
  if jq -e . "$REPO_SETTINGS_SRC" >/dev/null 2>&1; then
    cp "$REPO_SETTINGS_SRC" "$tmp_repo_json"
  else
    strip_jsonc_to_json "$REPO_SETTINGS_SRC" >"$tmp_repo_json" || true
    if ! jq -e . "$tmp_repo_json" >/dev/null 2>&1; then
      rm -f "$tmp_user_json" "$tmp_repo_json" 2>/dev/null || true
      put_error_banner_repo "$SETTINGS_PATH" "repo settings JSON invalid → $REPO_SETTINGS_SRC; skipped merge." "repo settings.json" "$REPO_SETTINGS_SRC"
      abort_or_continue "[Bootstrap config]" "repo settings JSON invalid → $REPO_SETTINGS_SRC; skipped merge."
      rm -f "$tmp_preserve_keys" 2>/dev/null || true
      return 0
    fi
  fi

  # keys managed by repo (in order) + previously managed snapshot
  RS_KEYS_JSON="$(jq 'keys' "$tmp_repo_json")"
  if [ -f "$MANAGED_KEYS_FILE" ] && jq -e . "$MANAGED_KEYS_FILE" >/dev/null 2>&1; then
    OLD_KEYS_JSON="$(cat "$MANAGED_KEYS_FILE")"
  else
    OLD_KEYS_JSON='[]'
  fi

  # ----- merge honoring inline //preserve -----
  # Build a JSON array of preserve keys from the temp file
  PRES_KEYS_JSON="$(awk 'BEGIN{printf("["); first=1} {gsub(/"/,"\\\""); if(!first) printf(","); printf("\"%s\"",$0); first=0} END{printf("]")}' "$tmp_preserve_keys")"

  tmp_merged="$(mktemp)"
  jq \
    --argjson repo "$(cat "$tmp_repo_json")" \
    --argjson rskeys "$RS_KEYS_JSON" \
    --argjson oldkeys "$OLD_KEYS_JSON" \
    --argjson pres "$PRES_KEYS_JSON" '
      def arr(v): if (v|type)=="array" then v else [] end;
      def minus($a; $b): [ $a[] | select( ($b | index(.)) | not ) ];
      def delKeys($obj; $ks): reduce $ks[] as $k ($obj; del(.[$k]));

      (. // {}) as $user
      | (delKeys($user; minus($oldkeys; $rskeys))) as $tmp_user
      | (delKeys($tmp_user; $rskeys)) as $user_without_repo
      | reduce $rskeys[] as $k (
          $user_without_repo;
          .[$k] =
            ( if ($pres | index($k)) and ($user | has($k))
              then $user[$k]                 # preserved → keep the user value
              else $repo[$k]                 # otherwise repo wins
              end )
        )
    ' "$tmp_user_json" > "$tmp_merged"

  # snapshot of currently managed keys (for future cleanups)
  tmp_managed_snapshot="$(mktemp)"
  jq \
    --argjson ks "$RS_KEYS_JSON" '
      . as $src
      | reduce $ks[] as $k ({}; if $src | has($k) then .[$k] = $src[$k] else . end)
    ' "$tmp_merged" > "$tmp_managed_snapshot"
  printf "%s" "$RS_KEYS_JSON" > "$MANAGED_KEYS_FILE" || true
  chown "${PUID}:${PGID}" "$MANAGED_KEYS_FILE" 2>/dev/null || true

  # ----- split merged → managed-only + extras (user-defined) -----
  tmp_managed_obj="$(mktemp)"
  jq --argjson ks "$RS_KEYS_JSON" '
    . as $src
    | reduce $ks[] as $k ({}; if $src | has($k) then .[$k] = $src[$k] else . end)
  ' "$tmp_merged" > "$tmp_managed_obj"

  tmp_extras_obj="$(mktemp)"
  jq --argjson ks "$RS_KEYS_JSON" '
    . as $src
    | reduce ($src|keys[]) as $k ({};
        if ($ks | index($k)) then . else .[$k] = $src[$k] end)
  ' "$tmp_merged" > "$tmp_extras_obj"

  # pretty-print, then strip outer braces to insert section comments
  managed_body="$(mktemp)"; jq '.' "$tmp_managed_obj" | sed '1d;$d' > "$managed_body"
  extras_body="$(mktemp)";  jq '.' "$tmp_extras_obj"  | sed '1d;$d' > "$extras_body"

  have_managed=0; [ -s "$managed_body" ] && have_managed=1
  have_extras=0;  [ -s "$extras_body" ]  && have_extras=1

  # ----- re-insert //preserve on the same line as preserved keys (managed section) -----
  # Build an awk map of preserved keys; whenever we see   "key":   at top level, append //preserve
  managed_with_preserve="$(mktemp)"
  awk -v KFILE="$tmp_preserve_keys" '
    BEGIN {
      while ((getline k < KFILE) > 0) pres[k] = 1
      close(KFILE)
    }
    {
      line = $0
      # Detect a top-level setting line:   "key": <value>
      if (match(line, /^[[:space:]]*\"[^\"]+\"[[:space:]]*:/)) {
        ms = substr(line, RSTART, RLENGTH)
        q1 = index(ms, "\"")
        if (q1 > 0) {
          rest = substr(ms, q1 + 1)
          q2 = index(rest, "\"")
          if (q2 > 1) {
            key = substr(rest, 1, q2 - 1)
            if (key in pres) {
              # If there is a trailing comma, keep it BEFORE the comment
              if (line ~ /,[[:space:]]*$/) {
                sub(/,[[:space:]]*$/, "", line)
                sub(/[[:space:]]*$/, "", line)
                line = line ", //preserve"
              } else {
                sub(/[[:space:]]*$/, "", line)
                line = line " //preserve"
              }
            }
          }
        }
      }
      print line
    }
  ' "$managed_body" > "$managed_with_preserve"

  # add a trailing comma between sections (but keep it BEFORE //preserve if present)
  managed_final="$managed_with_preserve"
  if [ $have_managed -eq 1 ] && [ $have_extras -eq 1 ]; then
    managed_final2="$(mktemp)"
    awk '
      { if ($0 ~ /[^[:space:]]/) { last=NR } lines[NR]=$0 }
      END {
        for (i=1; i<=NR; i++) {
          if (i==last) {
            l = lines[i]
            sub(/[[:space:]]*$/, "", l)
            if (l ~ /\/\/[[:space:]]*preserve[[:space:]]*$/) {
              # move the comma BEFORE the comment
              sub(/[[:space:]]*\/\/[[:space:]]*preserve[[:space:]]*$/, ", //preserve", l)
              print l
            } else {
              print l ","
            }
          } else {
            print lines[i]
          }
        }
      }
    ' "$managed_with_preserve" > "$managed_final2"
    managed_final="$managed_final2"
  fi

  # ----- compose final with bracket comments -----
  tmp_with_comments="$(mktemp)"
  {
    echo "{"
    echo "  //codestrap merged settings:"
    if [ $have_managed -eq 1 ]; then sed 's/^/  /' "$managed_final"; fi
    echo "  //user defined settings:"
    if [ $have_extras -eq 1 ];  then sed 's/^/  /' "$extras_body";  fi
    echo "}"
  } > "$tmp_with_comments"

  write_inplace "$tmp_with_comments" "$SETTINGS_PATH"
  chown "${PUID}:${PGID}" "$SETTINGS_PATH" 2>/dev/null || true
  clear_error_banner "$SETTINGS_PATH"

  rm -f "$tmp_user_json" "$tmp_repo_json" "$tmp_merged" \
        "$tmp_managed_snapshot" "$tmp_managed_obj" "$tmp_extras_obj" \
        "$managed_body" "$managed_with_preserve" "$managed_final" \
        "$extras_body" "$tmp_with_comments" "$tmp_preserve_keys" 2>/dev/null || true

  log "merged settings.json → $SETTINGS_PATH"
}

# ===== keybindings.json merge =====
merge_codestrap_keybindings(){
  REPO_KEYB_SRC="${REPO_KEYB_SRC:-$HOME/codestrap/keybindings.json}"
  [ -f "$REPO_KEYB_SRC" ] || { log "no repo keybindings.json; skipping keybindings merge"; return 0; }
  command -v jq >/dev/null 2>&1 || { warn "jq not available; skipping keybindings merge"; return 0; }

  ensure_dir "$USER_DIR"; ensure_dir "$STATE_DIR"

  # --- canonical short id (8 chars) for a keybinding object ---
  kb_hash(){ jq -cS . | tr -d '\n\t ' | sha1sum | awk '{print substr($1,1,8)}'; }

  # ---- Load USER (parsed JSON for data), keep raw file for comment scan ----
  tmp_user_json="$(mktemp)"
  if [ -f "$KEYB_PATH" ]; then
    if jq -e . "$KEYB_PATH" >/dev/null 2>&1; then
      cp "$KEYB_PATH" "$tmp_user_json"
    else
      strip_jsonc_to_json "$KEYB_PATH" >"$tmp_user_json" || true
      if ! jq -e . "$tmp_user_json" >/dev/null 2>&1; then
        rm -f "$tmp_user_json" 2>/dev/null || true
        put_error_banner_this "$KEYB_PATH" "user keybindings.json is malformed; skipped merge to avoid data loss."
        abort_or_continue "[Bootstrap config]" "user keybindings.json is malformed; skipped merge to avoid data loss."
        return 0
      fi
    fi
  else
    printf '[]\n' >"$tmp_user_json"
  fi

  # ---- Load REPO (allow comments only) ----
  tmp_repo_json="$(mktemp)"
  if jq -e . "$REPO_KEYB_SRC" >/dev/null 2>&1; then
    cp "$REPO_KEYB_SRC" "$tmp_repo_json"
  else
    strip_jsonc_to_json "$REPO_KEYB_SRC" >"$tmp_repo_json" || true
    if ! jq -e . "$tmp_repo_json" >/dev/null 2>&1; then
      rm -f "$tmp_user_json" "$tmp_repo_json" 2>/dev/null || true
      put_error_banner_repo "$KEYB_PATH" "repo keybindings JSON invalid → $REPO_KEYB_SRC; skipped merge." "repo keybindings.json" "$REPO_KEYB_SRC"
      abort_or_continue "[Bootstrap config]" "repo keybindings JSON invalid → $REPO_KEYB_SRC; skipped merge."
      return 0
    fi
  fi

  # === PASS 1: RAW user scan (comments) → (idx → id) and (id → preserved props)
  tmp_id_by_index_txt="$(mktemp)"; : >"$tmp_id_by_index_txt"   # "<idx>\t<id>"
  tmp_preserve_pairs="$(mktemp)";   : >"$tmp_preserve_pairs"   # "<id>\t<prop>"

  if [ -f "$KEYB_PATH" ]; then
    _banner_strip_first_if_error <"$KEYB_PATH" | awk -v O1="$tmp_id_by_index_txt" -v O2="$tmp_preserve_pairs" '
      function cnt(re,s, t){ t=s; return gsub(re,"&",t) }
      BEGIN{ arr=0; inObj=0; obj=0; idx=-1; cur="" }
      {
        s=$0
        arr += cnt(/\[/,s); arr -= cnt(/\]/,s)
        if (!inObj && arr==1 && cnt(/\{/,s)>0){ inObj=1; obj = cnt(/\{/,s)-cnt(/\}/,s); idx++; cur="" }
        else if (inObj){ obj += cnt(/\{/,s); obj -= cnt(/\}/,s) }

        if (inObj && s ~ /\/\/[[:space:]]*id#[0-9a-fA-F]+/){
          t=s; sub(/^.*id#/,"",t); sub(/[^0-9a-fA-F].*$/,"",t); cur=t
        }

        if (inObj && cur!="" && s ~ /\/\/[[:space:]]*preserve[[:space:]]*$/ && s ~ /^[[:space:]]*"[^"]+"\s*:/){
          p=s; sub(/^[[:space:]]*"/,"",p); sub(/".*$/,"",p); print cur "\t" p >> O2
        }

        if (inObj && obj<=0){
          if(cur!="") print idx "\t" cur >> O1
          inObj=0
        }
      }
    '
  fi

  # Convert idx→id TSV to JSON array [{i:<num>, id:"..."}]
  tmp_idx_arr="$(mktemp)"
  if [ -s "$tmp_id_by_index_txt" ]; then
    awk -F'\t' 'NF==2{printf("{\"i\":%d,\"id\":\"%s\"}\n",$1,$2)}' "$tmp_id_by_index_txt" | jq -s '.' > "$tmp_idx_arr"
  else
    printf '[]\n' > "$tmp_idx_arr"
  fi

  # Build id → [props...]
  tmp_preserve_json="$(mktemp)"
  if [ -s "$tmp_preserve_pairs" ]; then
    awk -F'\t' 'NF==2{printf("{\"id\":\"%s\",\"prop\":\"%s\"}\n",$1,$2)}' "$tmp_preserve_pairs" \
      | jq -s 'reduce .[] as $e ({}; .[$e.id] = ((.[$e.id] // []) + [$e.prop]))' > "$tmp_preserve_json"
  else
    printf '{}\n' > "$tmp_preserve_json"
  fi

  # === Build repo array with __tmp_id (hash) — no argjson involved
  tmp_repo_with_ids="$(mktemp)"
  jq -c '.[] | select(type=="object")' "$tmp_repo_json" | while IFS= read -r robj; do
    [ -n "$robj" ] || continue
    rid="$(printf '%s' "$robj" | kb_hash)"
    printf '%s\n' "$robj" | jq --arg id "$rid" '. + { "__tmp_id": $id }'
  done | jq -s '.' > "$tmp_repo_with_ids"

  # === Merge (all via slurpfiles) ===
  tmp_both="$(mktemp)"
  jq -n \
    --slurpfile U "$tmp_user_json" \
    --slurpfile R "$tmp_repo_with_ids" \
    --slurpfile P "$tmp_preserve_json" \
    --slurpfile IDX "$tmp_idx_arr" '
      def arr(x): if (x|type)=="array" then x else [] end;
      def obj(x): if (x|type)=="object" then x else {} end;

      (arr($U[0]))  as $Uraw
      | (arr($R[0])) as $R
      | (obj($P[0])) as $PRES
      | (arr($IDX[0])) as $IDX

      # id -> full user object (from captured indices)
      | ( reduce $IDX[] as $e ({};
            .[$e.id] = ( ($Uraw[$e.i] // {}) | select(type=="object") )
        )
        ) as $U_by_id

      # repo-first, overlay preserved props from matching user object by id
      | ( $R
          | map(
              . as $repo
              | ($repo.__tmp_id // null) as $id
              | if $id != null and ($U_by_id[$id]? != null) then
                  ($U_by_id[$id]) as $u
                  | ($PRES[$id] // []) as $keep
                  | reduce $keep[] as $k (
                      $repo;
                      if ($u[$k]? != null) then .[$k] = $u[$k] else . end
                    )
                else
                  .
                end
            )
        ) as $managed

      # user extras = entries that had no id comment (indices not in IDX)
      | ( $IDX | map(.i) ) as $seen
      | ( [ $Uraw | to_entries[]
            | select(.value|type=="object")
            | select( ($seen | index(.key)) == null )
            | .value
          ] ) as $extras

      | { managed: $managed, extras: $extras, mlen: ($managed|length), elen: ($extras|length) }
  ' > "$tmp_both"

  mlen="$(jq -r '.mlen' "$tmp_both")"
  elen="$(jq -r '.elen' "$tmp_both")"

  # Pretty-print arrays and strip outer brackets
  tmp_managed_arr="$(mktemp)"; jq '.managed' "$tmp_both" > "$tmp_managed_arr"
  tmp_extras_arr="$(mktemp)";  jq '.extras'  "$tmp_both" > "$tmp_extras_arr"
  managed_body="$(mktemp)"; sed '1d;$d' "$tmp_managed_arr" > "$managed_body"
  extras_body="$(mktemp)";   sed '1d;$d' "$tmp_extras_arr"  > "$extras_body"

  # Insert //id#... at top of each managed object; drop __tmp_id; clean trailing commas
  managed_annotated="$(mktemp)"
  awk '
    function indent(s,t){ t=s; match(t,/^[[:space:]]*/); return substr(t,RSTART,RLENGTH) }
    BEGIN{ inObj=0; id="" }
    {
      l=$0
      if (!inObj) {
        if (l ~ /^[[:space:]]*{[[:space:]]*$/) { inObj=1; n=0; id=""; i=indent(l); buf[++n]=l }
        else print l
      } else {
        buf[++n]=l
        if (l ~ /^[[:space:]]*"__tmp_id"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]+"/) {
          id=l; sub(/^.*"__tmp_id"[[:space:]]*:[[:space:]]*"/,"",id); sub(/".*$/,"",id)
        }
        if (l ~ /^[[:space:]]*}[[:space:]]*,?[[:space:]]*$/) {
          outn=0; out[++outn]=buf[1]
          if (id!="") out[++outn]=i "  //id#" id
          for(k=2;k<=n;k++){ t=buf[k]; if (t ~ /^[[:space:]]*"__tmp_id"[[:space:]]*:/) continue; out[++outn]=t }
          closei=outn; while(closei>1 && out[closei] ~ /^[[:space:]]*$/) closei--
          if (out[closei] ~ /^[[:space:]]*}[[:space:]]*,?[[:space:]]*$/) {
            prev=closei-1; while(prev>1 && out[prev] ~ /^[[:space:]]*$/) prev--
            if (prev>1) sub(/,[[:space:]]*$/,"",out[prev])
          }
          for(k=1;k<=outn;k++) print out[k]
          inObj=0
        }
      }
    }
  ' "$managed_body" > "$managed_annotated"

  # Re-add //preserve to preserved props; comma stays before the comment
  managed_with_preserve="$(mktemp)"
  awk -v MAP="$tmp_preserve_pairs" '
    BEGIN{
      while((getline m<MAP)>0){ p=index(m,"\t"); if(p>0){ keep[substr(m,1,p-1) "\t" substr(m,p+1)]=1 } }
      close(MAP); cur=""
    }
    {
      l=$0
      if (l ~ /\/\/[[:space:]]*id#[0-9a-fA-F]+/) { cur=l; sub(/^.*id#/,"",cur); sub(/[^0-9a-fA-F].*$/, "", cur) }
      if (cur!="" && l ~ /^[[:space:]]*"[^"]+"\s*:/) {
        prop=l; sub(/^[[:space:]]*"/,"",prop); sub(/".*$/,"",prop)
        if (keep[cur "\t" prop]) {
          if (l ~ /,[[:space:]]*$/) { sub(/,[[:space:]]*$/,"",l); sub(/[[:space:]]*$/,"",l); l=l ", //preserve" }
          else                       { sub(/[[:space:]]*$/,"",l);  l=l " //preserve" }
        }
      }
      print l
    }
  ' "$managed_annotated" > "$managed_with_preserve"

  # If both segments exist, add a comma to the last managed line (before //preserve if present)
  managed_final="$managed_with_preserve"
  if [ -s "$extras_body" ] && [ -s "$managed_with_preserve" ]; then
    managed_final2="$(mktemp)"
    awk '
      { if ($0 ~ /[^[:space:]]/) last=NR; lines[NR]=$0 }
      END{
        for(i=1;i<=NR;i++){
          if(i==last){
            l=lines[i]; sub(/[[:space:]]*$/,"",l)
            if (l ~ /\/\/[[:space:]]*preserve[[:space:]]*$/) { sub(/[[:space:]]*\/\/[[:space:]]*preserve[[:space:]]*$/, ", //preserve", l); print l }
            else print l ","
          } else print lines[i]
        }
      }
    ' "$managed_with_preserve" > "$managed_final2"
    managed_final="$managed_final2"
  fi

  # ---- assemble final ----
  tmp_with_comments="$(mktemp)"
  {
    echo "["
    echo "  //codestrap merged keybindings:"
    if [ -s "$managed_final" ]; then sed 's/^/  /' "$managed_final"; fi
    echo "  //user defined keybindings:"
    if [ -s "$extras_body" ]; then sed 's/^/  /' "$extras_body"; fi
    echo "]"
  } > "$tmp_with_comments"

  write_inplace "$tmp_with_comments" "$KEYB_PATH"
  chown "${PUID}:${PGID}" "$KEYB_PATH" 2>/dev/null || true
  clear_error_banner "$KEYB_PATH"

  rm -f "$tmp_user_json" "$tmp_repo_json" \
        "$tmp_id_by_index_txt" "$tmp_preserve_pairs" "$tmp_idx_arr" "$tmp_preserve_json" \
        "$tmp_repo_with_ids" "$tmp_both" \
        "$tmp_managed_arr" "$tmp_extras_arr" "$managed_body" "$extras_body" \
        "$managed_annotated" "$managed_with_preserve" "$managed_final" "$tmp_with_comments" 2>/dev/null || true

  log "merged keybindings.json → $KEYB_PATH"
}


# ===== extensions.json merge (recommendations array, repo-first, de-duped) =====
merge_codestrap_extensions(){
  REPO_EXT_SRC="${REPO_EXT_SRC:-$HOME/codestrap/extensions.json}"
  [ -f "$REPO_EXT_SRC" ] || { log "no repo extensions.json; skipping extensions merge"; return 0; }
  command -v jq >/dev/null 2>&1 || { warn "jq not available; skipping extensions merge"; return 0; }

  ensure_dir "$USER_DIR"; ensure_dir "$STATE_DIR"

  # --- helper: strip JSONC & trailing commas ---
  _strip_jsonc_trailing(){
    # removes //... and /*...*/ then trims trailing commas before ] or }
    sed -e 's://[^\r\n]*$::' -e '/\/\*/,/\*\//d' "$1" \
    | sed -E ':a; s/,\s*([}\]])/\1/g; ta'
  }

  # Load USER (allow comments + trailing commas; validate after repair)
  tmp_user_json="$(mktemp)"
  if [ -f "$EXT_PATH" ]; then
    if jq -e . "$EXT_PATH" >/dev/null 2>&1; then
      cp "$EXT_PATH" "$tmp_user_json"
    else
      # user extensions invalid → skip on init, exit on cli
      _strip_jsonc_trailing "$EXT_PATH" > "$tmp_user_json" || true
      if ! jq -e . "$tmp_user_json" >/dev/null 2>&1; then
        rm -f "$tmp_user_json" 2>/dev/null || true
        put_error_banner_this "$EXT_PATH" "user extensions.json is malformed; skipped merge to avoid data loss."
        abort_or_continue "[Bootstrap config]" "user extensions.json is malformed; skipped merge to avoid data loss."
        return 0
      fi
    fi
  else
    printf '{ "recommendations": [] }\n' > "$tmp_user_json"
  fi

  # Load REPO (allow comments + trailing commas; validate after repair)
  tmp_repo_json="$(mktemp)"
  if jq -e . "$REPO_EXT_SRC" >/dev/null 2>&1; then
    cp "$REPO_EXT_SRC" "$tmp_repo_json"
  else
    # repo extensions invalid → skip on init, exit on cli
    _strip_jsonc_trailing "$REPO_EXT_SRC" > "$tmp_repo_json" || true
    if ! jq -e . "$tmp_repo_json" >/dev/null 2>&1; then
      rm -f "$tmp_user_json" "$tmp_repo_json" 2>/dev/null || true
      put_error_banner_repo "$EXT_PATH" "repo extensions JSON invalid → $REPO_EXT_SRC; skipped merge." "repo extensions.json" "$REPO_EXT_SRC"
      abort_or_continue "[Bootstrap config]" "repo extensions JSON invalid → $REPO_EXT_SRC; skipped merge."
      return 0
    fi
  fi

  # Extract repo list (de-dup preserving order)
  tmp_repo_list="$(mktemp)"
  jq -r '.recommendations // [] | .[] | @json' "$tmp_repo_json" | awk '!seen[$0]++' > "$tmp_repo_list"

  # Extract user extras (those NOT in repo list, preserving order)
  tmp_user_extras="$(mktemp)"
  jq -n --slurpfile u "$tmp_user_json" --slurpfile r "$tmp_repo_json" '
    def arr(v): if (v|type)=="array" then v else [] end;
    ( $r[0].recommendations // [] ) as $RR
    | ( $u[0].recommendations // [] ) as $UR
    | [ $UR[] | select( . as $x | ($RR | index($x)) | not ) ]
  ' | jq -r '.[] | @json' > "$tmp_user_extras"

  # Compose final WITH inline comments around repo segment, but NEVER emit trailing commas.
  tmp_with_comments="$(mktemp)"
  {
    echo "{"
    echo '  "recommendations": ['
    echo '    //codestrap merged extensions:'

    first=1
    # repo items first
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      if [ $first -eq 0 ]; then
        printf ",\n"
      fi
      printf "    %s" "$item"
      first=0
    done < "$tmp_repo_list"

    # If we printed at least one repo item and there WILL be extras,
    # print the comma NOW so it's on the same line as the last repo item.
    if [ $first -eq 0 ]; then
      if [ -s "$tmp_user_extras" ]; then
        printf ",\n"
      else
        printf "\n"
      fi
    fi

    echo '    //user defined extensions:'

    # then user extras (own comma handling)
    first_e=1
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      if [ $first_e -eq 0 ]; then
        printf ",\n"
      fi
      printf "    %s" "$item"
      first_e=0
    done < "$tmp_user_extras"

    # close the array/object
    [ $first -eq 0 -o $first_e -eq 0 ] && printf "\n"
    echo "  ]"
    echo "}"
  } > "$tmp_with_comments"

  # Write result (preserve inode to keep watchers alive)
  write_inplace "$tmp_with_comments" "$EXT_PATH"
  chown "${PUID}:${PGID}" "$EXT_PATH" 2>/dev/null || true
  clear_error_banner "$EXT_PATH"
  rm -f "$tmp_user_json" "$tmp_repo_json" "$tmp_repo_list" "$tmp_user_extras" "$tmp_with_comments" 2>/dev/null || true
  log "merged extensions.json → $EXT_PATH"
}

# ===== extension management (install/update/uninstall using code-server/VS Code CLI) =====
detect_code_cli(){
  if command -v code-server >/dev/null 2>&1; then echo "code-server"; return 0; fi
  if command -v code >/dev/null 2>&1; then echo "code"; return 0; fi
  echo ""
}

emit_recommended_exts(){
  [ -f "$EXT_PATH" ] || return 0
  tmp="$(mktemp)"
  if jq -e . "$EXT_PATH" >/dev/null 2>&1; then
    cp "$EXT_PATH" "$tmp"
  else
    strip_jsonc_to_json "$EXT_PATH" >"$tmp" || true
    jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 0; }
  fi
  jq -r '.recommendations // [] | .[] | strings' "$tmp" 2>/dev/null | awk 'NF' | awk '!seen[$0]++'
  rm -f "$tmp" 2>/dev/null || true
}

emit_installed_exts(){
  CODE_BIN="$(detect_code_cli)"; [ -n "$CODE_BIN" ] || return 0
  "$CODE_BIN" --list-extensions 2>/dev/null | awk 'NF' | awk '!seen[$0]++'
}

emit_installed_exts_with_versions(){
  CODE_BIN="$(detect_code_cli)"; [ -n "$CODE_BIN" ] || return 0
  "$CODE_BIN" --list-extensions --show-versions 2>/dev/null | awk 'NF' | awk '!seen[$0]++'
}

install_one_ext(){
  ext="$1"; force="${2:-false}"
  CODE_BIN="$(detect_code_cli)"; [ -n "$CODE_BIN" ] || { warn "code CLI not found; cannot install ${ext}"; return 1; }
  if [ "$force" = "true" ]; then
    "$CODE_BIN" --install-extension "$ext" --force >/dev/null 2>&1
  else
    "$CODE_BIN" --install-extension "$ext" >/dev/null 2>&1
  fi
}

uninstall_one_ext(){
  ext="$1"
  CODE_BIN="$(detect_code_cli)"; [ -n "$CODE_BIN" ] || { warn "code CLI not found; cannot uninstall ${ext}"; return 1; }
  "$CODE_BIN" --uninstall-extension "$ext" >/dev/null 2>&1
}

in_file(){ needle="$1"; file="$2"; grep -F -x -q -- "$needle" "$file" 2>/dev/null; }

normalize_scope(){ case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in a|all) echo "all";; m|missing) echo "missing";; *) echo ""; esac; }

extensions_cmd(){
  # Parse flags
  MODE=""         # install scope: "", "all", "missing"
  UNMODE=""       # uninstall scope: "", "all", "missing"
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        cat <<'EHELP'
Usage:
  codestrap extensions
    → interactive: choose install or uninstall, then scope (all/missing)

  codestrap extensions -i all|a
  codestrap extensions -i missing|m
  codestrap extensions -u all|a
  codestrap extensions -u missing|m
  # Combine:
  codestrap extensions -i m -u m

This uses extensions listed in your merged extensions.json at:
  $HOME/data/User/extensions.json
EHELP
        exit 0;;
      --install|-i)
        if [ "$1" = "-i" ]; then shift || true; MODE="$(normalize_scope "${1:-}")"; else shift || true; MODE="$(normalize_scope "${1:-}")"; fi
        [ -n "$MODE" ] || { CTX_TAG="[Extensions]"; err "Flag '--install|-i' requires <all|a|missing|m>"; CTX_TAG=""; exit 2; }
        ;;
      --install=*)
        MODE="$(normalize_scope "${1#*=}")"
        [ -n "$MODE" ] || { CTX_TAG="[Extensions]"; err "Flag '--install' requires <all|a|missing|m>"; CTX_TAG=""; exit 2; }
        ;;
      --uninstall|-u)
        if [ "$1" = "-u" ]; then shift || true; UNMODE="$(normalize_scope "${1:-}")"; else shift || true; UNMODE="$(normalize_scope "${1:-}")"; fi
        [ -n "$UNMODE" ] || { CTX_TAG="[Extensions]"; err "Flag '--uninstall|-u' requires <all|a|missing|m>"; CTX_TAG=""; exit 2; }
        ;;
      --uninstall=*)
        UNMODE="$(normalize_scope "${1#*=}")"
        [ -n "$UNMODE" ] || { CTX_TAG="[Extensions]"; err "Flag '--uninstall' requires <all|a|missing|m>"; CTX_TAG=""; exit 2; }
        ;;
      *)
        CTX_TAG="[Extensions]"; err "Unknown flag for 'extensions': $1"; CTX_TAG=""; exit 1;;
    esac
    shift || true
  done

  CODE_BIN="$(detect_code_cli)"
  [ -n "$CODE_BIN" ] || { CTX_TAG="[Extensions]"; warn "code-server/VS Code CLI not found; cannot manage extensions"; CTX_TAG=""; exit 0; }

  tmp_recs="$(mktemp)"; tmp_installed="$(mktemp)"
  emit_recommended_exts >"$tmp_recs" || true
  emit_installed_exts >"$tmp_installed" || true

  # Build sets
  tmp_missing="$(mktemp)"; : >"$tmp_missing"         # in recs but not installed
  tmp_present_rec="$(mktemp)"; : >"$tmp_present_rec" # in recs and installed
  tmp_not_recommended="$(mktemp)"; : >"$tmp_not_recommended" # installed but NOT in recs

  # Index installed for quick checks
  while IFS= read -r ext; do
    [ -n "$ext" ] || continue
    if in_file "$ext" "$tmp_recs"; then
      echo "$ext" >>"$tmp_present_rec"
    else
      echo "$ext" >>"$tmp_not_recommended"
    fi
  done <"$tmp_installed"

  while IFS= read -r ext; do
    [ -n "$ext" ] || continue
    if ! in_file "$ext" "$tmp_installed"; then
      echo "$ext" >>"$tmp_missing"
    fi
  done <"$tmp_recs"

  do_uninstall(){
    scope="$1"
    CTX_TAG="[Extensions]"
    case "$scope" in
      all)
        if [ -s "$tmp_installed" ]; then
          log "uninstalling ALL installed extensions"
          while IFS= read -r ext; do
            [ -n "$ext" ] || continue
            if uninstall_one_ext "$ext"; then
              log "uninstalled ${ext}"
            else
              warn "failed to uninstall ${ext}"
            fi
          done <"$tmp_installed"
        else
          log "no installed extensions to uninstall"
        fi
        ;;
      missing)
        if [ -s "$tmp_not_recommended" ]; then
          log "uninstalling extensions not in recommendations (cleanup)"
          while IFS= read -r ext; do
            [ -n "$ext" ] || continue
            if uninstall_one_ext "$ext"; then
              log "uninstalled ${ext}"
            else
              warn "failed to uninstall ${ext}"
            fi
          done <"$tmp_not_recommended"
        else
          log "no non-recommended extensions to uninstall"
        fi
        ;;
    esac
    CTX_TAG=""
  }

  do_install(){
    scope="$1"
    CTX_TAG="[Extensions]"
    case "$scope" in
      missing)
        if [ -s "$tmp_missing" ]; then
          log "installing missing recommended extensions"
          while IFS= read -r ext; do
            [ -n "$ext" ] || continue
            if install_one_ext "$ext" "false"; then
              log "installed ${ext}"
            else
              warn "failed to install ${ext}"
            fi
          done <"$tmp_missing"
        else
          log "no missing recommended extensions"
        fi
        ;;
      all)
        if [ -s "$tmp_missing" ]; then
          log "installing missing recommended extensions"
          while IFS= read -r ext; do
            [ -n "$ext" ] || continue
            if install_one_ext "$ext" "false"; then
              log "installed ${ext}"
            else
              warn "failed to install ${ext}"
            fi
          done <"$tmp_missing"
        else
          log "no missing recommended extensions"
        fi
        if [ -s "$tmp_present_rec" ]; then
          log "updating already-installed recommended extensions to latest"
          while IFS= read -r ext; do
            [ -n "$ext" ] || continue
            if install_one_ext "$ext" "true"; then
              log "updated ${ext}"
            else
              warn "failed to update ${ext}"
            fi
          done <"$tmp_present_rec"
        else
          log "no already-installed recommended extensions to update"
        fi
        ;;
    esac
    CTX_TAG=""
  }

  if [ -z "$MODE" ] && [ -z "$UNMODE" ]; then
    # Interactive: pick action then scope
    PROMPT_TAG="[Extensions] ? "
    CTX_TAG="[Extensions]"

    act_raw="$(prompt_def "Action (install|uninstall) [install]: " "install")"
    act="$(printf "%s" "$act_raw" | tr '[:upper:]' '[:lower:]')"
    case "$act" in
      i|install|"") act="install" ;;
      u|uninstall)  act="uninstall" ;;
      *) log "unknown action '$act_raw' → defaulting to install"; act="install" ;;
    esac

    if [ "$act" = "install" ]; then
      scope_raw="$(prompt_def "Install scope (all|missing) [missing]: " "missing")"
      MODE="$(normalize_scope "$scope_raw")"; [ -n "$MODE" ] || MODE="missing"
      do_install "$MODE"
    else
      scope_raw="$(prompt_def "Uninstall scope (all|missing) [missing]: " "missing")"
      UNMODE="$(normalize_scope "$scope_raw")"; [ -n "$UNMODE" ] || UNMODE="missing"
      if [ "$UNMODE" = "all" ]; then
        conf="$(prompt_def "This will remove ALL installed extensions. Continue? (y/N) " "n")"
        [ "$(yn_to_bool "$conf")" = "true" ] || { log "aborted uninstall all"; PROMPT_TAG=""; CTX_TAG=""; rm -f "$tmp_recs" "$tmp_installed" "$tmp_missing" "$tmp_present_rec" "$tmp_not_recommended"; exit 0; }
      fi
      do_uninstall "$UNMODE"
    fi
    PROMPT_TAG=""
    CTX_TAG=""
  else
    # Non-interactive: ALWAYS uninstall first (if requested), then install (if requested)
    if [ -n "$UNMODE" ]; then do_uninstall "$UNMODE"; fi
    if [ -n "$MODE" ]; then do_install "$MODE"; fi
  fi

  rm -f "$tmp_recs" "$tmp_installed" "$tmp_missing" "$tmp_present_rec" "$tmp_not_recommended" 2>/dev/null || true
}

# ===== CLI helpers =====
install_cli_shim(){
  # System-wide install when root, else user-level install into ~/.local/bin
  if require_root; then
    mkdir -p /usr/local/bin
    cat >/usr/local/bin/codestrap <<'EOF'
#!/usr/bin/env sh
set -eu
for TARGET in /custom-cont-init.d/10-codestrap.sh; do
  if [ -e "$TARGET" ]; then
    if [ -x "$TARGET" ]; then
      exec "$TARGET" cli "$@"
    else
      exec sh "$TARGET" cli "$@"
    fi
  fi
done
echo "[codestrap][ERROR] launcher script not found." >&2
exit 127
EOF
    chmod 755 /usr/local/bin/codestrap
    echo "${CODESTRAP_VERSION:-0.3.8}" >/etc/codestrap-version 2>/dev/null || true
    log "installed CLI shim → /usr/local/bin/codestrap"
  else
    # Non-root fallback: user-level install
    mkdir -p "$HOME/.local/bin"
    cat >"$HOME/.local/bin/codestrap" <<'EOF'
#!/usr/bin/env sh
set -eu
for TARGET in /custom-cont-init.d/10-codestrap.sh; do
  if [ -e "$TARGET" ]; then
    if [ -x "$TARGET" ]; then
      exec "$TARGET" cli "$@"
    else
      exec sh "$TARGET" cli "$@"
    fi
  fi
done
echo "[codestrap][ERROR] launcher script not found." >&2
exit 127
EOF
    chmod 755 "$HOME/.local/bin/codestrap"
    case ":$PATH:" in *":$HOME/.local/bin:"*) : ;; *) log "note: ensure \$HOME/.local/bin is on PATH to use 'codestrap' command";; esac
    log "installed CLI shim → $HOME/.local/bin/codestrap"
  fi
}

bootstrap_banner(){ if has_tty; then printf "\n[codestrap] Interactive bootstrap — press Ctrl+C to abort.\n" >/dev/tty; else log "No TTY; use flags or --auto."; fi; }

# --- interactive GitHub flow ---
bootstrap_interactive(){
  GITHUB_USERNAME="$(read_or_env "GitHub username" GITHUB_USERNAME "")"; ORIGIN_GITHUB_USERNAME="${ORIGIN_GITHUB_USERNAME:-prompt}"
  GITHUB_TOKEN="$(read_secret_or_env "GitHub token (classic: user:email, admin:public_key)" GITHUB_TOKEN)"; ORIGIN_GITHUB_TOKEN="${ORIGIN_GITHUB_TOKEN:-prompt}"
  GITHUB_NAME="$(read_or_env "GitHub name [${GITHUB_NAME:-${GITHUB_USERNAME:-}}]" GITHUB_NAME "${GITHUB_NAME:-${GITHUB_USERNAME:-}}")"
  GITHUB_EMAIL="$(read_or_env "GitHub email (blank=auto)" GITHUB_EMAIL "")"
  GITHUB_REPOS="$(read_or_env "Repos (comma-separated owner/repo[#branch])" GITHUB_REPOS "${GITHUB_REPOS:-}")"
  GITHUB_PULL="$(read_bool_or_env "Pull existing repos? [Y/n]" GITHUB_PULL "y")"
  [ -n "${GITHUB_USERNAME:-}" ] || { echo "GITHUB_USERNAME or --username required." >&2; exit 2; }
  [ -n "${GITHUB_TOKEN:-}" ]     || { echo "GITHUB_TOKEN or --token required." >&2; exit 2; }
  export GITHUB_USERNAME GITHUB_TOKEN GITHUB_NAME GITHUB_EMAIL GITHUB_REPOS GITHUB_PULL ORIGIN_GITHUB_USERNAME ORIGIN_GITHUB_TOKEN
  codestrap_run; log "bootstrap complete"
}

bootstrap_env_only(){
  ORIGIN_GITHUB_USERNAME="${ORIGIN_GITHUB_USERNAME:-env GITHUB_USERNAME}"
  ORIGIN_GITHUB_TOKEN="${ORIGIN_GITHUB_TOKEN:-env GITHUB_TOKEN}"
  [ -n "${GITHUB_USERNAME:-}" ] || { echo "GITHUB_USERNAME or --username required (env)." >&2; exit 2; }
  [ -n "${GITHUB_TOKEN:-}" ]     || { echo "GITHUB_TOKEN or --token required (env)." >&2; exit 2; }
  export ORIGIN_GITHUB_USERNAME ORIGIN_GITHUB_TOKEN
  codestrap_run; log "bootstrap complete (env)"
}

recompute_base(){
  WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/workspace}"
  WORKSPACE_DIR="$(printf '%s' "$WORKSPACE_DIR" | sed 's:/*$::')"
  ensure_dir "$WORKSPACE_DIR"
  REPOS_SUBDIR="${REPOS_SUBDIR:-repos}"
  REPOS_SUBDIR="$(printf '%s' "$REPOS_SUBDIR" | sed 's:^/*::; s:/*$::')"
  if [ -n "$REPOS_SUBDIR" ]; then
    BASE="${WORKSPACE_DIR}/${REPOS_SUBDIR}"
  else
    BASE="${WORKSPACE_DIR}"
  fi
  ensure_dir "$BASE"
}

# --- interactive config flow (manual flow) ---
config_interactive(){
  PROMPT_TAG="[Bootstrap config] ? "
  CTX_TAG="[Bootstrap config]"
  ensure_preserve_store
  if [ "$(prompt_yn "merge strapped settings.json to user settings.json? (Y/n)" "y")" = "true" ]; then
    merge_codestrap_settings
  else
    log "skipped settings merge"
  fi

  if [ "$(prompt_yn "merge strapped keybindings.json to user settings.json? (Y/n)" "y")" = "true" ]; then
    merge_codestrap_keybindings
  else
    log "skipped keybindings merge"
  fi

  if [ "$(prompt_yn "merge strapped extensions.json to user settings.json? (Y/n)" "y")" = "true" ]; then
    merge_codestrap_extensions
  else
    log "skipped extensions merge"
  fi

  log "Bootstrap config completed"
  PROMPT_TAG=""
  CTX_TAG=""
}

# --- hybrid / flag-aware config flow ---
config_hybrid(){
  PROMPT_TAG="[Bootstrap config] ? "
  CTX_TAG="[Bootstrap config]"
  ensure_preserve_store
  
  # --settings
  if [ -n "${CFG_SETTINGS+x}" ]; then
    if [ "$(normalize_bool "$CFG_SETTINGS")" = "true" ]; then
      merge_codestrap_settings
    else
      log "skipped settings merge"
    fi
  else
    if [ "$(prompt_yn "merge strapped settings.json to user settings.json? (Y/n)" "y")" = "true" ]; then
      merge_codestrap_settings
    else
      log "skipped settings merge"
    fi
  fi

  # --keybindings
  if [ -n "${CFG_KEYB+x}" ]; then
    if [ "$(normalize_bool "$CFG_KEYB")" = "true" ]; then
      merge_codestrap_keybindings
    else
      log "skipped keybindings merge"
    fi
  else
    if [ "$(prompt_yn "merge strapped keybindings.json to user settings.json? (Y/n)" "y")" = "true" ]; then
      merge_codestrap_keybindings
    else
      log "skipped keybindings merge"
    fi
  fi

  # --extensions
  if [ -n "${CFG_EXT+x}" ]; then
    if [ "$(normalize_bool "$CFG_EXT")" = "true" ]; then
      merge_codestrap_extensions
    else
      log "skipped extensions merge"
    fi
  else
    if [ "$(prompt_yn "merge strapped extensions.json to user settings.json? (Y/n)" "y")" = "true" ]; then
      merge_codestrap_extensions
    else
      log "skipped extensions merge"
    fi
  fi

  log "Bootstrap config completed"
  PROMPT_TAG=""
  CTX_TAG=""
}

# ===== github flags handler =====
bootstrap_from_args(){ # used by: codestrap github [flags...]
  USE_ENV=false
  # Clear any old values (so flags fully control when provided)
  unset GITHUB_USERNAME GITHUB_TOKEN GITHUB_NAME GITHUB_EMAIL GITHUB_REPOS GITHUB_PULL
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)     print_help; exit 0;;
      -v|--version)  print_version; exit 0;;
      -a|--auto)     USE_ENV=true;;
      -u|--username) shift || true; GITHUB_USERNAME="${1:-}";;
      -t|--token)    shift || true; GITHUB_TOKEN="${1:-}";;
      -n|--name)     shift || true; GITHUB_NAME="${1:-}";;
      -e|--email)    shift || true; GITHUB_EMAIL="${1:-}";;
      -r|--repos)    shift || true; GITHUB_REPOS="${1:-}";;
      -p|--pull)     shift || true; GITHUB_PULL="${1:-true}";;
      --*)           err "Unknown flag '$1'"; print_help; exit 1;;
      *)             err "Unknown argument: $1"; print_help; exit 1;;
    esac
    shift || true
  done

  recompute_base

  if [ "$USE_ENV" = "true" ]; then
    ORIGIN_GITHUB_USERNAME="${ORIGIN_GITHUB_USERNAME:-env GITHUB_USERNAME}"
    ORIGIN_GITHUB_TOKEN="${ORIGIN_GITHUB_TOKEN:-env GITHUB_TOKEN}"
  else
    if ! is_tty; then
      echo "No TTY available for prompts. Use flags or --auto. Examples:
  GITHUB_USERNAME=alice GITHUB_TOKEN=ghp_xxx codestrap github --auto
  codestrap github -u alice -t ghp_xxx -r \"alice/app#main\"
" >&2
      exit 3
    fi
    bootstrap_banner
    PROMPT_TAG="[Bootstrap GitHub] ? "
    CTX_TAG="[Bootstrap GitHub]"
    bootstrap_interactive
    PROMPT_TAG=""
    CTX_TAG=""
    return 0
  fi

  [ -n "${GITHUB_USERNAME:-}" ] || { echo "GITHUB_USERNAME or --username required (flag/env/prompt)." >&2; exit 2; }
  [ -n "${GITHUB_TOKEN:-}" ]     || { echo "GITHUB_TOKEN or --token required (flag/env/prompt)." >&2; exit 2; }

  CTX_TAG="[Bootstrap GitHub]"
  export GITHUB_USERNAME GITHUB_TOKEN GITHUB_NAME GITHUB_EMAIL GITHUB_REPOS GITHUB_PULL BASE WORKSPACE_DIR REPOS_SUBDIR ORIGIN_GITHUB_USERNAME ORIGIN_GITHUB_TOKEN
  codestrap_run
  log "bootstrap complete"
  CTX_TAG=""
}

# ===== top-level CLI entry with subcommands =====
cli_entry(){

  if [ $# -eq 0 ]; then
    # Hub flow
    if ! is_tty; then
      echo "No TTY detected. Run a subcommand or provide flags. Examples:
  codestrap github --auto
  codestrap config
  codestrap passwd
" >&2
      exit 3
    fi

    # Show banner BEFORE first hub question
    bootstrap_banner()

    # 1) GitHub?
    if has_tty; then printf "\n" >/dev/tty; else printf "\n"; fi
    if [ "$(prompt_yn "Bootstrap GitHub? (Y/n)" "y")" = "true" ]; then
      PROMPT_TAG="[Bootstrap GitHub] ? "
      CTX_TAG="[Bootstrap GitHub]"
      bootstrap_interactive
      PROMPT_TAG=""
      CTX_TAG=""
    else
      CTX_TAG="[Bootstrap GitHub]"
      log "skipped bootstrap GitHub"
      CTX_TAG=""
    fi
    # 2) Config?
    if has_tty; then printf "\n" >/dev/tty; else printf "\n"; fi
    if [ "$(prompt_yn "Bootstrap config? (Y/n)" "y")" = "true" ]; then
      config_interactive
    else
      CTX_TAG="[Bootstrap config]"; log "skipped bootstrap config"; CTX_TAG=""
    fi

    # 3) Password?  (no prefix on question; default YES)
    if has_tty; then printf "\n" >/dev/tty; else printf "\n"; fi
    CTX_TAG="[Change password]"
    if [ "$(prompt_yn "Change password? (Y/n)" "y")" = "true" ]; then
      password_change_interactive
    else
      log "skipped change password"
    fi
    PROMPT_TAG=""
    CTX_TAG=""
    exit 0
  fi

  # Subcommands
  case "$1" in
    -h|--help)    print_help; exit 0;;
    -v|--version) print_version; exit 0;;
    github)
      shift || true
      if [ $# -eq 0 ]; then
        if is_tty; then
          bootstrap_banner
          PROMPT_TAG="[Bootstrap GitHub] ? "
          CTX_TAG="[Bootstrap GitHub]"
          bootstrap_interactive
          PROMPT_TAG=""
          CTX_TAG=""
        else
          echo "Use flags or --auto for non-interactive github flow."; exit 3
        fi
      else
        bootstrap_from_args "$@"
      fi
      ;;
    config)
      shift || true
      # Parse config flags
      unset CFG_SETTINGS
      unset CFG_KEYB
      unset CFG_EXT
      while [ $# -gt 0 ]; do
        case "$1" in
          -h|--help) print_help; exit 0;;
          -s|--settings)
            shift || true
            CFG_SETTINGS="${1:-}"
            [ -n "${CFG_SETTINGS:-}" ] || { CTX_TAG="[Bootstrap config]"; err "Flag '--settings|-s' requires <true|false>"; CTX_TAG=""; exit 2; }
            ;;
          --settings=*)
            CFG_SETTINGS="${1#*=}"
            ;;
          -k|--keybindings)
            shift || true
            CFG_KEYB="${1:-}"
            [ -n "${CFG_KEYB:-}" ] || { CTX_TAG="[Bootstrap config]"; err "Flag '--keybindings|-k' requires <true|false>"; CTX_TAG=""; exit 2; }
            ;;
          --keybindings=*)
            CFG_KEYB="${1#*=}"
            ;;
          -e|--extensions)
            shift || true
            CFG_EXT="${1:-}"
            [ -n "${CFG_EXT:-}" ] || { CTX_TAG="[Bootstrap config]"; err "Flag '--extensions|-e' requires <true|false>"; CTX_TAG=""; exit 2; }
            ;;
          --extensions=*)
            CFG_EXT="${1#*=}"
            ;;
          *)
            CTX_TAG="[Bootstrap config]"; err "Unknown flag for 'config': $1"; CTX_TAG=""; print_help; exit 1;;
        esac
        shift || true
      done

      if is_tty; then
        bootstrap_banner
        config_hybrid
      else
        CTX_TAG="[Bootstrap config]"
        ensure_preserve_store
        # Non-interactive defaults to true unless explicitly set
        if [ -n "${CFG_SETTINGS+x}" ]; then
          if [ "$(normalize_bool "$CFG_SETTINGS")" = "true" ]; then merge_codestrap_settings; else log "skipped settings merge"; fi
        else
          merge_codestrap_settings
        fi
        if [ -n "${CFG_KEYB+x}" ]; then
          if [ "$(normalize_bool "$CFG_KEYB")" = "true" ]; then merge_codestrap_keybindings; else log "skipped keybindings merge"; fi
        else
          merge_codestrap_keybindings
        fi
        if [ -n "${CFG_EXT+x}" ]; then
          if [ "$(normalize_bool "$CFG_EXT")" = "true" ]; then merge_codestrap_extensions; else log "skipped extensions merge"; fi
        else
          merge_codestrap_extensions
        fi
        log "Bootstrap config completed"
        CTX_TAG=""
      fi
      ;;
    extensions)
      shift || true
      extensions_cmd "$@"
      ;;
    --auto|-a)
      CTX_TAG="[Bootstrap GitHub]"; bootstrap_env_only; CTX_TAG=""; exit 0;;
    passwd)
      bootstrap_banner
      CTX_TAG="[Change password]"
      password_change_interactive
      CTX_TAG=""
      exit 0;;
    *)
      err "Unknown subcommand: $1"; print_help; exit 1;;
  esac
}

# ===== autorun at container start (env-driven) =====
autorun_env_if_present(){
  if [ -n "${GITHUB_USERNAME:-}" ] && [ -n "${GITHUB_TOKEN:-}" ] && [ ! -f "$LOCK_FILE" ]; then
    : > "$LOCK_FILE" || true
    log "env present and no lock → running bootstrap"
    if ! codestrap_run; then
      CTX_TAG="[Bootstrap GitHub]"; err "env bootstrap failed (continuing)"; CTX_TAG=""
    fi
  else
    [ -f "$LOCK_FILE" ] && log "init lock present → skip duplicate autorun"
    { [ -z "${GITHUB_USERNAME:-}" ] || [ -z "${GITHUB_TOKEN:-}" ] ; } && log "GITHUB_USERNAME/GITHUB_TOKEN missing → no autorun"
  fi
}

# ===== init-time extensions automation via env (UNINSTALL then INSTALL) =====
autorun_install_extensions(){
  # Normalize envs
  inst_mode="$(printf "%s" "${EXTENSIONS_INSTALL:-}"   | tr '[:upper:]' '[:lower:]')"
  uninst_mode="$(printf "%s" "${EXTENSIONS_UNINSTALL:-}" | tr '[:upper:]' '[:lower:]')"

  run_noninteractive(){
    um="$1"; im="$2"
    args=""
    case "$um" in all|a) args="$args --uninstall all";; missing|m) args="$args --uninstall missing";; esac
    case "$im" in all|a) args="$args --install all";;   missing|m) args="$args --install missing";; esac
    if [ -n "$args" ]; then
      CTX_TAG="[Extensions]"
      log "env automation → codestrap extensions$args"
      CTX_TAG=""
      extensions_cmd $args
    fi
  }

  case "$uninst_mode" in all|a|missing|m|none|"") : ;; *) CTX_TAG="[Extensions]"; warn "EXTENSIONS_UNINSTALL invalid: '$uninst_mode' (use all|missing|none)"; CTX_TAG=""; uninst_mode="";; esac
  case "$inst_mode"   in all|a|missing|m|none|"") : ;; *) CTX_TAG="[Extensions]"; warn "EXTENSIONS_INSTALL invalid: '$inst_mode' (use all|missing|none)";     CTX_TAG=""; inst_mode="";; esac

  [ "$uninst_mode" = "none" ] && uninst_mode=""
  [ "$inst_mode"   = "none" ] && inst_mode=""

  [ -z "$uninst_mode$inst_mode" ] && return 0

  run_noninteractive "$uninst_mode" "$inst_mode"
}

# ===== entrypoint =====
case "${1:-init}" in
  init)
    RUN_MODE="init"
    safe_run "[Restart gate]"            install_restart_gate
    safe_run "[CLI shim]"                install_cli_shim
    safe_run "[Default password]"        init_default_password
    safe_run "[Preserve store]"          ensure_preserve_store
    safe_run "[Bootstrap config]"        merge_codestrap_settings
    safe_run "[Bootstrap config]"        merge_codestrap_keybindings
    safe_run "[Bootstrap config]"        merge_codestrap_extensions
    safe_run "[Bootstrap GitHub]"        autorun_env_if_present
    safe_run "[Extensions env]"          autorun_install_extensions
    log "Codestrap initialized. Use: codestrap -h"
    ;;
  cli)
    RUN_MODE="cli"
    shift; cli_entry "$@"
    ;;
  *)
    if [ $# -gt 0 ]; then set -- cli "$@"; exec "$0" "$@"; else set -- init; exec "$0" "$@"; fi
    ;;
esac
