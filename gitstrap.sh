#!/usr/bin/env sh
# gitstrap — bootstrap GitHub + manage code-server auth (CLI-first)
set -eu

VERSION="${GITSTRAP_VERSION:-0.3.0}"

log(){ echo "[gitstrap] $*"; }
warn(){ echo "[gitstrap][WARN] $*" >&2; }
err(){ printf "\033[31m[gitstrap][ERROR] %s\033[0m\n" "$*" >&2; }
redact(){ echo "$1" | sed 's/[A-Za-z0-9_\-]\{12,\}/***REDACTED***/g'; }
ensure_dir(){ mkdir -p "$1" 2>/dev/null || true; chown -R "${PUID:-1000}:${PGID:-1000}" "$1" 2>/dev/null || true; }

# robust TTY checks
has_tty(){ [ -c /dev/tty ] && [ -r /dev/tty ] && [ -w /dev/tty ]; }
is_tty(){ [ -t 0 ] && [ -t 1 ] || has_tty; }

# prompts via /dev/tty when possible
read_line(){ if has_tty; then IFS= read -r _l </dev/tty || true; else IFS= read -r _l || true; fi; printf "%s" "${_l:-}"; }
prompt(){ msg="$1"; if has_tty; then printf "%s" "$msg" >/dev/tty; else printf "%s" "$msg"; fi; read_line; }
prompt_def(){ v="$(prompt "$1")"; [ -n "$v" ] && printf "%s" "$v" || printf "%s" "$2"; }
prompt_secret(){
  if has_tty; then
    printf "%s" "$1" >/dev/tty
    stty -echo </dev/tty >/dev/tty 2>/dev/null || true
    IFS= read -r s </dev/tty || true
    stty echo </dev/tty >/dev/tty 2>/dev/null || true
    printf "\n" >/dev/tty 2>/dev/null || true
  else
    printf "%s" "$1"; IFS= read -r s || true
  fi; printf "%s" "${s:-}"
}
yn_to_bool(){ case "$(printf "%s" "$1" | tr '[:upper:]' '[:lower:]')" in y|yes|t|true|1) echo "true";; *) echo "false";; esac; }
normalize_bool(){ v="${1:-true}"; [ "$(printf '%s' "$v" | cut -c1 | tr '[:upper:]' '[:lower:]')" = "f" ] && echo false || echo true; }

print_help(){
cat <<'HLP'
gitstrap — bootstrap GitHub + manage code-server auth

Usage:
  gitstrap                               # interactive bootstrap (prompts if TTY)
  gitstrap --env | -e                    # bootstrap using environment variables only
  gitstrap [flags...]                    # non-interactive bootstrap using provided flags/env
  gitstrap passwd                        # interactive password change (secure prompts)
  gitstrap settings-merge                # merge gitstrap settings.json into user settings.json and exit
  gitstrap -h | --help                   # help
  gitstrap -v | --version                # version

Power-user flags (1:1 with env vars; dash or underscore both accepted):
  --gh-username | --gh_username <val>        → GH_USERNAME
  --gh-pat      | --gh_pat      <val>        → GH_PAT   (classic; scopes: user:email, admin:public_key)
  --git-name    | --git_name    <val>        → GIT_NAME
  --git-email   | --git_email   <val>        → GIT_EMAIL
  --gh-repos    | --gh_repos    "<specs>"    → GH_REPOS (owner/repo, owner/repo#branch, https://github.com/owner/repo)
  --pull-existing-repos | --pull_existing_repos <true|false> → PULL_EXISTING_REPOS (default: true)
  --workspace-dir  | --workspace_dir <dir>   → WORKSPACE_DIR (default: /config/workspace)
  --repos-subdir   | --repos_subdir  <dir>   → REPOS_SUBDIR  (default: repos)
  --env | -e                                   Use environment variables only (no prompts)

Notes:
  • Flags override environment. Unknown flags are rejected.
  • Without flags, if in a TTY gitstrap prompts; otherwise use --env or flags.
  • You can mix flags + envs; flags win.

Examples:
  gitstrap
  GH_USERNAME=alice GH_PAT=ghp_xxx gitstrap --env
  gitstrap --gh-username alice --gh-pat ghp_xxx --gh-repos "alice/app#main, org/infra"
  gitstrap --pull-existing-repos false
  gitstrap settings-merge
  gitstrap passwd
HLP
}

print_version(){ echo "gitstrap ${VERSION}"; }

print_logo(){
  is_tty || return 0
  cat <<'LOGO'
          $$\   $$\                 $$\                                  
          \__|  $$ |                $$ |                                 
 $$$$$$\  $$\ $$$$$$\    $$$$$$$\ $$$$$$\    $$$$$$\  $$$$$$\   $$$$$$\  
$$  __$$\ $$ |\_$$  _|  $$  _____|\_$$  _|  $$  __$$\ \____$$\ $$  __$$\ 
$$ /  $$ |$$ |  $$ |    \$$$$$$\    $$ |    $$ |  \__|$$$$$$$ |$$ /  $$ |
$$ |  $$ |$$ |  $$ |$$\  \____$$\   $$ |$$\ $$ |     $$  __$$ |$$ |  $$ |
\$$$$$$$ |$$ |  \$$$$  |$$$$$$$  |  \$$$$  |$$ |     \$$$$$$$ |$$$$$$$  |
 \____$$ |\__|   \____/ \_______/    \____/ \__|      \_______|$$  ____/ 
$$\   $$ |                                                     $$ |      
\$$$$$$  |                                                     $$ |      
 \______/                                                      \__|      
LOGO
  echo
}

# ===== paths / state =====
export HOME="${HOME:-/config}"
PUID="${PUID:-1000}"; PGID="${PGID:-1000}"

STATE_DIR="$HOME/.gitstrap"; ensure_dir "$STATE_DIR"
LOCK_DIR="/run/gitstrap";    ensure_dir "$LOCK_DIR"
LOCK_FILE="$LOCK_DIR/init-gitstrap.lock"

PASS_HASH_PATH="${FILE__HASHED_PASSWORD:-$STATE_DIR/password.hash}"
FIRSTBOOT_MARKER="$STATE_DIR/.firstboot-auth-restart"

# Workspace & repos (REPOS_SUBDIR is relative to WORKSPACE_DIR)
WORKSPACE_DIR="${WORKSPACE_DIR:-/config/workspace}"; ensure_dir "$WORKSPACE_DIR"
REPOS_SUBDIR_RAW="${REPOS_SUBDIR:-repos}"
REPOS_SUBDIR="$(printf "%s" "$REPOS_SUBDIR_RAW" | sed 's#^/*##; s#/*$##;')"
[ -n "$REPOS_SUBDIR" ] && BASE="$WORKSPACE_DIR/$REPOS_SUBDIR" || BASE="$WORKSPACE_DIR"
ensure_dir "$BASE"

SSH_DIR="$HOME/.ssh"; ensure_dir "$SSH_DIR"
KEY_NAME="id_ed25519"; PRIVATE_KEY_PATH="$SSH_DIR/$KEY_NAME"; PUBLIC_KEY_PATH="$SSH_DIR/${KEY_NAME}.pub"

# VS Code settings merge
USER_DIR="$HOME/data/User"; ensure_dir "$USER_DIR"
SETTINGS_PATH="$USER_DIR/settings.json"
TASKS_PATH="$USER_DIR/tasks.json"
KEYBINDINGS_PATH="$USER_DIR/keybindings.json"
EXTENSIONS_PATH="$USER_DIR/extensions.json"
REPO_SETTINGS_SRC="$HOME/gitstrap/settings.json"
MANAGED_KEYS_FILE="$STATE_DIR/managed-settings-keys.json"

# config-shortcuts (symlinks under workspace)
SHORTCUTS_DIR="$WORKSPACE_DIR/config-shortcuts"

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

# ===== password change =====
password_change_interactive(){
  command -v argon2 >/dev/null 2>&1 || { err "argon2 not found."; return 1; }
  NEW="$(prompt_secret "New code-server password: ")"
  CONF="$(prompt_secret "Confirm password: ")"
  [ -n "$NEW" ] || { err "password required."; return 1; }
  [ -n "$CONF" ] || { err "confirmation required."; return 1; }
  [ "$NEW" = "$CONF" ] || { err "passwords do not match."; return 1; }
  [ ${#NEW} -ge 8 ] || { err "minimum length 8."; return 1; }
  salt="$(head -c16 /dev/urandom | base64)"
  hash="$(printf '%s' "$NEW" | argon2 "$salt" -id -e)"
  printf '%s' "$hash" > "$PASS_HASH_PATH"; chmod 644 "$PASS_HASH_PATH" || true; chown "${PUID}:${PGID}" "$PASS_HASH_PATH" 2>/dev/null || true
  printf "\n\033[1;33m*** CODE-SERVER PASSWORD CHANGED ***\n*** REFRESH PAGE TO LOGIN ***\033[0m\n\n"
  trigger_restart_gate
}

# ===== GitHub validations =====
validate_github_pat(){
  GH_PAT="${GH_PAT:-}"
  [ -n "$GH_PAT" ] || return 0

  # Probe /user for validity
  status="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: token ${GH_PAT}" \
    -H "User-Agent: gitstrap" \
    -H "Accept: application/vnd.github+json" \
    https://api.github.com/user || true)"

  if [ "$status" = "401" ] || [ "$status" = "403" ]; then
    err "Provided GH_PAT (--gh-pat) is invalid or lacks access (HTTP $status). Provide a valid classic PAT with scopes: user:email, admin:public_key."
    exit 10
  elif [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
    warn "Unexpected response probing PAT (HTTP $status). Continuing, but key upload/email lookup may fail."
    return 0
  fi

  # Scope hints (classic PATs usually include this header)
  headers="$(curl -fsS -D - -o /dev/null \
    -H "Authorization: token ${GH_PAT}" \
    -H "User-Agent: gitstrap" \
    -H "Accept: application/vnd.github+json" \
    https://api.github.com/user 2>/dev/null || true)"

  scopes="$(printf "%s" "$headers" \
    | tr -d '\r' \
    | grep -i '^x-oauth-scopes:' \
    | sed -E 's/^x-oauth-scopes:[[:space:]]*//I' \
    | sed -E 's/[[:space:]]*$//')"

  if [ -n "$scopes" ]; then
    echo "$scopes" | grep -qiE '(^|, *)admin:public_key(,|$)' || warn "GH_PAT may be missing 'admin:public_key' (needed to upload SSH key). Current scopes: $scopes"
    echo "$scopes" | grep -qiE '(^|, *)user:email(,|$)'       || warn "GH_PAT may be missing 'user:email' (needed to resolve your primary email). Current scopes: $scopes"
  fi
}

validate_github_username(){
  GH_USERNAME="${GH_USERNAME:-}"
  [ -n "$GH_USERNAME" ] || return 0
  ustatus="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "User-Agent: gitstrap" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/users/${GH_USERNAME}" || true)"
  if [ "$ustatus" = "404" ]; then
    err "GitHub username '${GH_USERNAME}' not found (HTTP 404)."
    exit 11
  fi
}

# ===== github bootstrap internals =====
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
  RESP="$(curl -fsS -X POST -H "Authorization: token ${GH_PAT}" -H "Accept: application/vnd.github+json" -d "{\"title\":\"$GH_KEY_TITLE\",\"key\":\"$LOCAL_KEY\"}" https://api.github.com/user/keys || true)"
  echo "$RESP" | grep -q '"id"' && log "SSH key added" || { err "Key upload failed: $(redact "$RESP")"; exit 12; }
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
    *) err "Invalid repo spec: $spec"; exit 13;;
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
    if [ -n "$branch" ]; then git clone --branch "$branch" --single-branch "$url" "$dest" || { err "clone failed: $spec"; exit 14; }
    else git clone "$url" "$dest" || { err "clone failed: $spec"; exit 14; }
    fi
  fi
  chown -R "$PUID:$PGID" "$dest" || true
}

# ===== settings.json merge (repo -> user) with preserve and inline JSONC comments =====
strip_jsonc_to_json(){ sed -e 's://.*$::' -e '/\/\*/,/\*\//d' "$1"; }

install_settings_from_repo(){
  [ -f "$REPO_SETTINGS_SRC" ] || { log "no repo settings.json; skipping settings merge"; return 0; }
  command -v jq >/dev/null 2>&1 || { warn "jq not available; skipping settings merge"; return 0; }

  ensure_dir "$USER_DIR"; ensure_dir "$STATE_DIR"

  # Normalize user settings to JSON (handle JSONC)
  tmp_user_json="$(mktemp)"
  if [ ! -f "$SETTINGS_PATH" ] || ! jq -e . "$SETTINGS_PATH" >/dev/null 2>&1; then
    if [ -f "$SETTINGS_PATH" ]; then strip_jsonc_to_json "$SETTINGS_PATH" >"$tmp_user_json" || printf '{}\n' >"$tmp_user_json"; else printf '{}\n' >"$tmp_user_json"; fi
  else
    cp "$SETTINGS_PATH" "$tmp_user_json"
  fi
  jq -e . "$tmp_user_json" >/dev/null 2>&1 || printf '{}\n' >"$tmp_user_json"

  # Validate repo settings
  if ! jq -e . "$REPO_SETTINGS_SRC" >/dev/null 2>&1; then
    warn "repo settings JSON invalid → $REPO_SETTINGS_SRC ; skipping"
    rm -f "$tmp_user_json" 2>/dev/null || true
    return 0
  fi

  RS_KEYS_JSON="$(jq 'keys' "$REPO_SETTINGS_SRC")"

  if [ -f "$MANAGED_KEYS_FILE" ] && jq -e . "$MANAGED_KEYS_FILE" >/dev/null 2>&1; then
    OLD_KEYS_JSON="$(cat "$MANAGED_KEYS_FILE")"
  else
    OLD_KEYS_JSON='[]'
  fi

  # Merge with preserve semantics
  tmp_merged="$(mktemp)"
  jq \
    --argjson repo "$(cat "$REPO_SETTINGS_SRC")" \
    --argjson rskeys "$RS_KEYS_JSON" \
    --argjson oldkeys "$OLD_KEYS_JSON" '
      def arr(v): if (v|type)=="array" then v else [] end;
      def minus($a; $b): [ $a[] | select( ($b | index(.)) | not ) ];
      def delKeys($obj; $ks): reduce $ks[] as $k ($obj; del(.[$k]));

      (. // {}) as $user
      | ($user.gitstrap_preserve // []) as $pres

      # remove keys previously managed but no longer in repo
      | (delKeys($user; minus($oldkeys; $rskeys))) as $tmp_user

      # remove current repo keys so we can re-add them
      | (delKeys($tmp_user; $rskeys)) as $user_without_repo

      # re-add repo keys, keep user values for preserved ones
      | reduce $rskeys[] as $k (
          $user_without_repo;
          .[$k] = ( if ($pres | index($k)) and ($user | has($k)) then $user[$k] else $repo[$k] end )
        )

      # ensure gitstrap_preserve exists
      | .gitstrap_preserve = arr($pres)
    ' "$tmp_user_json" > "$tmp_merged"

  # Managed-only object (repo keys only) — capture from merged (already contains repo values/preserves)
  tmp_managed="$(mktemp)"
  jq \
    --argjson ks "$RS_KEYS_JSON" '
      reduce $ks[] as $k ({}; if has($k) then .[$k] = .[$k] else . end)
    ' "$tmp_merged" > "$tmp_managed"

  # Rest object = merged minus (repo keys + gitstrap_preserve)
  tmp_rest="$(mktemp)"
  jq --argjson ks "$RS_KEYS_JSON" '
    def delKeys($o;$ks): reduce $ks[] as $k ($o; del(.[$k]));
    delKeys(.; ($ks + ["gitstrap_preserve"]))
  ' "$tmp_merged" > "$tmp_rest"

  preserve_json="$(jq -c '.gitstrap_preserve // []' "$tmp_merged")"
  mcount="$(jq 'keys|length' "$tmp_managed")"
  rcount="$(jq 'keys|length' "$tmp_rest")"

  # Assemble JSONC output (clean comma layout)
  {
    echo "{"
    echo "  // START gitstrap settings"
    if [ "$mcount" -gt 0 ]; then
      jq -r -j '
        to_entries
        | tostream
        | select(length==2)
        | .[1]
        | to_entries
        | map("  " + (.key|@json) + ": " + (.value|tojson))
        | join(",\n")
      ' "$tmp_managed"
      echo ","
    fi
    echo "  // gitstrap_preserve - enter key names of gitstrap merged settings here which you wish the gitstrap script not to overwrite"
    printf '  "gitstrap_preserve": %s\n' "$preserve_json"
    echo "  // END gitstrap settings"
    if [ "$rcount" -gt 0 ]; then
      echo "  ,"
      jq -r '
        to_entries
        | map("  " + (.key|@json) + ": " + (.value|tojson))
        | join(",\n")
      ' "$tmp_rest"
      echo
    fi
    echo "}"
  } > "$SETTINGS_PATH"

  chown "${PUID}:${PGID}" "$SETTINGS_PATH" 2>/dev/null || true
  printf "%s" "$RS_KEYS_JSON" > "$MANAGED_KEYS_FILE"; chown "${PUID}:${PGID}" "$MANAGED_KEYS_FILE" 2>/dev/null || true

  rm -f "$tmp_user_json" "$tmp_merged" "$tmp_managed" "$tmp_rest" 2>/dev/null || true
  log "merged settings.json → $SETTINGS_PATH"
}

# ===== config-shortcuts under workspace =====
setup_config_shortcuts(){
  ensure_dir "$SHORTCUTS_DIR"
  # create target files if missing so links resolve
  [ -f "$SETTINGS_PATH" ]    || printf '{}\n' > "$SETTINGS_PATH"
  [ -f "$TASKS_PATH" ]       || printf '[]\n' > "$TASKS_PATH"
  [ -f "$KEYBINDINGS_PATH" ] || printf '[]\n' > "$KEYBINDINGS_PATH"
  [ -f "$EXTENSIONS_PATH" ]  || printf '{ "recommendations": [] }\n' > "$EXTENSIONS_PATH"

  ln -snf "$SETTINGS_PATH"    "$SHORTCUTS_DIR/settings.json"
  ln -snf "$TASKS_PATH"       "$SHORTCUTS_DIR/tasks.json"
  ln -snf "$KEYBINDINGS_PATH" "$SHORTCUTS_DIR/keybindings.json"
  ln -snf "$EXTENSIONS_PATH"  "$SHORTCUTS_DIR/extensions.json"

  chown -h "${PUID}:${PGID}" "$SHORTCUTS_DIR"/* 2>/dev/null || true
  log "config-shortcuts ready at $SHORTCUTS_DIR"
}

# ===== flag → env mapping (1:1, dash/underscore agnostic) =====
ALLOWED_FLAG_VARS="GH_USERNAME GH_PAT GIT_NAME GIT_EMAIL GH_REPOS PULL_EXISTING_REPOS WORKSPACE_DIR REPOS_SUBDIR"
set_flag_env(){ # $1=flag key (already without leading --), $2=value
  norm="$(printf "%s" "$1" | tr '[:upper:]' '[:lower:]' | sed 's/-/_/g')"
  envname="$(printf "%s" "$norm" | tr '[:lower:]' '[:upper:]')"
  case " $ALLOWED_FLAG_VARS " in
    *" $envname "*) eval "export $envname=\$2";;
    *) err "Unknown or disallowed flag '--$1'"; print_help; exit 1;;
  esac
}

# ===== prompt helpers with per-field --env =====
use_env_token(){ case "$1" in -e|--env) echo "yes";; *) echo "no";; esac; }
prompt_with_env(){
  # $1 VAR (ENV name), $2 prompt text, $3 default
  VAR="$1"; MSG="$2"; DEF="$3"
  HINT=""; eval "cur=\${$VAR:-}"
  [ -n "$cur" ] && HINT=" (enter -e to use env $VAR)"
  ans="$(prompt "${MSG}${HINT}: ")"
  if [ "$(use_env_token "$ans")" = "yes" ]; then
    if [ -z "${cur:-}" ]; then err "env $VAR not set"; exit 20; fi
    printf "%s" "$cur"; return 0
  fi
  [ -n "$ans" ] && printf "%s" "$ans" || printf "%s" "$DEF"
}
prompt_secret_with_env(){
  VAR="$1"; MSG="$2"
  HINT=""; eval "cur=\${$VAR:-}"
  [ -n "$cur" ] && HINT=" (enter -e to use env $VAR)"
  ans="$(prompt "${MSG}${HINT}: ")"
  if [ "$(use_env_token "$ans")" = "yes" ]; then
    if [ -z "${cur:-}" ]; then err "env $VAR not set"; exit 21; fi
    printf "%s" "$cur"; return 0
  fi
  # read the secret now (without hint)
  prompt_secret ""
}

# ===== core run =====
gitstrap_run(){
  GH_USERNAME="${GH_USERNAME:-}"; GH_PAT="${GH_PAT:-}"
  GIT_NAME="${GIT_NAME:-${GH_USERNAME:-}}"; GIT_EMAIL="${GIT_EMAIL:-}"
  GH_REPOS="${GH_REPOS:-}"; PULL_EXISTING_REPOS="${PULL_EXISTING_REPOS:-true}"

  # Validate before doing work
  validate_github_username
  [ -n "$GH_PAT" ] && validate_github_pat

  git config --global init.defaultBranch main || true
  git config --global pull.ff only || true
  git config --global advice.detachedHead false || true
  git config --global --add safe.directory "*"
  git config --global user.name "${GIT_NAME:-gitstrap}" || true
  if [ -z "${GIT_EMAIL:-}" ]; then GIT_EMAIL="$(resolve_email || true)"; fi
  git config --global user.email "$GIT_EMAIL" || true
  log "identity: ${GIT_NAME:-} <${GIT_EMAIL:-}>"

  umask 077
  [ -f "$PRIVATE_KEY_PATH" ] || { log "Generating SSH key"; ssh-keygen -t ed25519 -f "$PRIVATE_KEY_PATH" -N "" -C "${GIT_EMAIL:-git@github.com}"; chmod 600 "$PRIVATE_KEY_PATH"; chmod 644 "$PUBLIC_KEY_PATH"; }
  touch "$SSH_DIR/known_hosts"; chmod 644 "$SSH_DIR/known_hosts" || true
  if command -v ssh-keyscan >/dev/null 2>&1 && ! grep -q "^github.com" "$SSH_DIR/known_hosts" 2>/dev/null; then ssh-keyscan github.com >> "$SSH_DIR/known_hosts" 2>/dev/null || true; fi
  git config --global core.sshCommand "ssh -i $PRIVATE_KEY_PATH -F /dev/null -o IdentitiesOnly=yes -o UserKnownHostsFile=$SSH_DIR/known_hosts -o StrictHostKeyChecking=accept-new"

  # upload key only if PAT present (and valid)
  if [ -n "$GH_PAT" ]; then git_upload_key; fi

  if [ -n "${GH_REPOS:-}" ]; then
    IFS=,; set -- $GH_REPOS; unset IFS
    for spec in "$@"; do clone_one "$spec" "$PULL_EXISTING_REPOS"; done
  else
    log "GH_REPOS empty; skip clone"
  fi
}

# ===== settings-only CLI =====
settings_merge_only(){
  install_settings_from_repo
  setup_config_shortcuts
  exit 0
}

# ===== CLI helpers =====
install_cli_shim(){
  require_root || return 0
  mkdir -p /usr/local/bin
  cat >/usr/local/bin/gitstrap <<'EOF'
#!/usr/bin/env sh
set -eu
TARGET="/custom-cont-init.d/10-gitstrap.sh"
# Always route through CLI sentinel so non-root usage never hits init path
if [ -x "$TARGET" ]; then exec "$TARGET" cli "$@"; else exec sh "$TARGET" cli "$@"; fi
EOF
  chmod 755 /usr/local/bin/gitstrap
  echo "${GITSTRAP_VERSION:-0.3.0}" >/etc/gitstrap-version 2>/dev/null || true
}

bootstrap_banner(){ if has_tty; then printf "\n[gitstrap] Interactive bootstrap — press Ctrl+C to abort.\n\n" >/dev/tty; else log "No TTY; use flags or --env."; fi; }
bootstrap_interactive(){
  bootstrap_banner
  GH_USERNAME="$(prompt_with_env GH_USERNAME "GitHub username" "${GH_USERNAME:-}")"
  GH_PAT_INPUT="$(prompt_with_env GH_PAT "GitHub PAT (classic: user:email, admin:public_key)" "")"
  [ -n "$GH_PAT_INPUT" ] && GH_PAT="$GH_PAT_INPUT" || GH_PAT="${GH_PAT:-}"
  GIT_NAME="$(prompt_with_env GIT_NAME "Git name" "${GIT_NAME:-$GH_USERNAME}")"
  GIT_EMAIL="$(prompt_with_env GIT_EMAIL "Git email (blank=auto)" "${GIT_EMAIL:-}")"
  GH_REPOS="$(prompt_with_env GH_REPOS "Repos (comma-separated owner/repo[#branch])" "${GH_REPOS:-}")"
  pull_def="y"; [ "$(normalize_bool "${PULL_EXISTING_REPOS:-true}")" = "false" ] && pull_def="n"
  pull_ans="$(prompt_with_env PULL_EXISTING_REPOS "Pull existing repos? [Y/n]" "$pull_def")"
  PULL_EXISTING_REPOS="$(yn_to_bool "$pull_ans")"

  [ -n "${GH_USERNAME:-}" ] || { err "GH_USERNAME or --gh-username required."; exit 2; }

  export GH_USERNAME GH_PAT GIT_NAME GIT_EMAIL GH_REPOS PULL_EXISTING_REPOS
  gitstrap_run; log "bootstrap complete"
}
bootstrap_env_only(){
  [ -n "${GH_USERNAME:-}" ] || { err "GH_USERNAME or --gh-username required (env)."; exit 2; }
  gitstrap_run; log "bootstrap complete (env)"
}

bootstrap_from_args(){
  USE_ENV=false
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)     print_help; exit 0;;
      -v|--version)  print_version; exit 0;;
      --env|-e)      USE_ENV=true;;
      passwd)        password_change_interactive; exit 0;;
      settings-merge) settings_merge_only;;
      --*)
        key="${1#--}"; shift || true
        val="${1:-}"
        [ -n "$val" ] && [ "${val#--}" = "$val" ] || { err "Flag '--$key' requires a value."; exit 2; }
        set_flag_env "$key" "$val"
        ;;
      *)
        err "Unknown argument: $1"; print_help; exit 1;;
    esac
    shift || true
  done

  # Recompute BASE if user changed WORKSPACE_DIR/REPOS_SUBDIR via flags
  WORKSPACE_DIR="${WORKSPACE_DIR:-/config/workspace}"; ensure_dir "$WORKSPACE_DIR"
  REPOS_SUBDIR_RAW="${REPOS_SUBDIR:-repos}"
  REPOS_SUBDIR="$(printf "%s" "$REPOS_SUBDIR_RAW" | sed 's#^/*##; s#/*$##;')"
  [ -n "$REPOS_SUBDIR" ] && BASE="$WORKSPACE_DIR/$REPOS_SUBDIR" || BASE="$WORKSPACE_DIR"
  ensure_dir "$BASE"

  if [ "$USE_ENV" = "true" ]; then
    bootstrap_env_only
  else
    if ! is_tty; then
      echo "No TTY available for prompts. Use flags or --env. Examples:
  GH_USERNAME=alice GH_PAT=ghp_xxx gitstrap --env
  gitstrap --gh-username alice --gh-pat ghp_xxx --gh-repos \"alice/app#main\"
" >&2
      exit 3
    fi
    bootstrap_interactive
  fi
}

cli_entry(){
  print_logo
  if [ $# -eq 0 ]; then
    if is_tty; then bootstrap_interactive; else
      echo "No TTY detected. Provide flags or use --env. Examples:
  GH_USERNAME=alice GH_PAT=ghp_xxx gitstrap --env
  gitstrap --gh-username alice --gh-pat ghp_xxx --gh-repos \"alice/app#main\"
" >&2
      exit 3
    fi
    exit 0
  fi
  case "$1" in
    -h|--help)    print_help; exit 0;;
    -v|--version) print_version; exit 0;;
    --env|-e)     bootstrap_env_only; exit 0;;
    passwd)       password_change_interactive; exit 0;;
    settings-merge) settings_merge_only;;
    *)            bootstrap_from_args "$@";;
  esac
}

# ===== autorun at container start (env-driven) =====
autorun_env_if_present(){
  if [ -n "${GH_USERNAME:-}" ] && [ -n "${GH_PAT:-}" ] && [ ! -f "$LOCK_FILE" ]; then
    : > "$LOCK_FILE" || true
    log "env present and no lock → running bootstrap"
    # Validate first; abort on error
    validate_github_username
    validate_github_pat
    gitstrap_run || true
  else
    [ -f "$LOCK_FILE" ] && log "init lock present → skip duplicate autorun"
    { [ -z "${GH_USERNAME:-}" ] || [ -z "${GH_PAT:-}" ]; } && log "GH_USERNAME/GH_PAT missing → no autorun"
  fi
}

# ===== entrypoint =====
case "${1:-init}" in
  init)
    install_restart_gate
    install_cli_shim
    init_default_password
    install_settings_from_repo
    setup_config_shortcuts
    autorun_env_if_present
    log "Gitstrap initialized. Use: gitstrap -h"
    ;;
  cli)
    shift; cli_entry "$@";;
  *)
    if [ $# -gt 0 ]; then set -- cli "$@"; exec "$0" "$@"; else set -- init; exec "$0" "$@"; fi
    ;;
esac
