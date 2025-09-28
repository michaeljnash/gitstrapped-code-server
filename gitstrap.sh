#!/usr/bin/env sh
# gitstrap — bootstrap GitHub + manage code-server auth (CLI-first)
set -eu

VERSION="${GITSTRAP_VERSION:-0.3.2}"

log(){ echo "[gitstrap] $*"; }
warn(){ echo "[gitstrap][WARN] $*" >&2; }
red(){ is_tty && printf "\033[31m%s\033[0m" "$1" || printf "%s" "$1"; }
ylw(){ is_tty && printf "\033[33m%s\033[0m" "$1" || printf "%s" "$1"; }
err(){ printf "%s\n" "$(red "[gitstrap][ERROR] $*")" >&2; }
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

# ---- banner ----
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

print_help(){
cat <<'HLP'
gitstrap — bootstrap GitHub + manage code-server auth

Usage:
  gitstrap                               # interactive bootstrap (prompts if TTY)
  gitstrap --env                         # bootstrap using environment variables only
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
  --workspace-dir       | --workspace_dir <dir>              → WORKSPACE_DIR (default: /config/workspace)
  --repos-subdir        | --repos_subdir  <rel>              → REPOS_SUBDIR (default: repos; treated RELATIVE to WORKSPACE_DIR, even if it starts with '/')
  --env                                                Use environment variables only (no prompts)

Notes:
  • Flags override environment. Unknown flags are rejected.
  • Without flags, if in a TTY gitstrap prompts; otherwise use --env or flags.
  • You can mix flags + envs; flags win.

Examples:
  gitstrap
  GH_USERNAME=alice GH_PAT=ghp_xxx gitstrap --env
  gitstrap --gh-username alice --gh-pat ghp_xxx --gh-repos "alice/app#main, org/infra"
  gitstrap --pull-existing-repos false
  gitstrap --workspace-dir /config/workspace --repos-subdir /repos
  gitstrap settings-merge
  gitstrap passwd
HLP
}

print_version(){ echo "gitstrap ${VERSION}"; }

# ===== paths / state =====
export HOME="${HOME:-/config}"
PUID="${PUID:-1000}"; PGID="${PGID:-1000}"

STATE_DIR="$HOME/.gitstrap"; ensure_dir "$STATE_DIR"
LOCK_DIR="/run/gitstrap";    ensure_dir "$LOCK_DIR"
LOCK_FILE="$LOCK_DIR/init-gitstrap.lock"

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

REPO_SETTINGS_SRC="$HOME/gitstrap/settings.json"
MANAGED_KEYS_FILE="$STATE_DIR/managed-settings-keys.json"

# Track origins for nicer errors
ORIGIN_GH_USERNAME="${ORIGIN_GH_USERNAME:-}"
ORIGIN_GH_PAT="${ORIGIN_GH_PAT:-}"

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

# ===== GitHub validation =====
validate_github_username(){
  [ -n "${GH_USERNAME:-}" ] || return 0
  code="$(curl -s -o /dev/null -w "%{http_code}" -H "Accept: application/vnd.github+json" "https://api.github.com/users/${GH_USERNAME}" || echo "000")"
  if [ "$code" = "404" ]; then
    src="${ORIGIN_GH_USERNAME:-env GH_USERNAME}"
    err "GitHub username '${GH_USERNAME}' appears invalid (HTTP 404). Check ${src}."
  elif [ "$code" != "200" ]; then
    warn "Could not verify GitHub username '${GH_USERNAME}' (HTTP $code)."
  fi
}

validate_github_pat(){
  [ -n "${GH_PAT:-}" ] || return 0
  # Check token validity
  code="$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token ${GH_PAT}" -H "Accept: application/vnd.github+json" https://api.github.com/user || echo "000")"
  src="${ORIGIN_GH_PAT:-env GH_PAT}"
  if [ "$code" = "401" ]; then
    err "Provided GH_PAT (${src}) is invalid or expired (HTTP 401). Please provide a valid classic PAT with scopes: user:email, admin:public_key."
    return 1
  elif [ "$code" = "403" ]; then
    err "Provided GH_PAT (${src}) is not authorized (HTTP 403). It may be missing required scopes: user:email, admin:public_key."
    return 1
  elif [ "$code" != "200" ]; then
    warn "Could not verify GH_PAT (${src}) (HTTP $code)."
    return 0
  fi
  # Scope hint (best-effort)
  headers="$(curl -fsS -D - -o /dev/null -H "Authorization: token ${GH_PAT}" -H "Accept: application/vnd.github+json" https://api.github.com/user 2>/dev/null || true)"
  scopes="$(printf "%s" "$headers" | awk -F': ' '/^[Xx]-[Oo]Auth-[Ss]copes:/ {gsub(/\r/,"",$2); print $2}')"
  echo "$scopes" | grep -q 'admin:public_key' || warn "$(ylw "GH_PAT may be missing 'admin:public_key' (needed to upload SSH key). Current scopes: ${scopes:-none}")"
  echo "$scopes" | grep -q 'user:email' || warn "$(ylw "GH_PAT may be missing 'user:email' (needed to resolve your primary email). Current scopes: ${scopes:-none}")"
}

# ===== password change =====
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
  printf '%s' "$hash" > "$PASS_HASH_PATH"; chmod 644 "$PASS_HASH_PATH" || true; chown "${PUID}:${PGID}" "$PASS_HASH_PATH" 2>/dev/null || true
  printf "\n\033[1;33m*** CODE-SERVER PASSWORD CHANGED ***\n*** REFRESH PAGE TO LOGIN ***\033[0m\n\n"
  trigger_restart_gate
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
    *) err "Invalid repo spec: '$spec'. Use owner/repo, owner/repo#branch, or a GitHub URL."; return 0;;
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
    if [ -n "$branch" ]; then git clone --branch "$branch" --single-branch "$url" "$dest" || { err "Clone failed for '$spec'"; return 0; }
    else git clone "$url" "$dest" || { err "Clone failed for '$spec'"; return 0; }
    fi
  fi
  chown -R "$PUID:$PGID" "$dest" || true
}
gitstrap_run(){
  GH_USERNAME="${GH_USERNAME:-}"; GH_PAT="${GH_PAT:-}"
  GIT_NAME="${GIT_NAME:-${GH_USERNAME:-}}"; GIT_EMAIL="${GIT_EMAIL:-}"
  GH_REPOS="${GH_REPOS:-}"; PULL_EXISTING_REPOS="${PULL_EXISTING_REPOS:-true}"

  # Validate inputs early for clearer UX
  validate_github_username || true
  validate_github_pat || true

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
  git_upload_key || true
  if [ -n "${GH_REPOS:-}" ]; then IFS=,; set -- $GH_REPOS; unset IFS; for spec in "$@"; do clone_one "$spec" "$PULL_EXISTING_REPOS"; done; else log "GH_REPOS empty; skip clone"; fi
}

# ===== settings.json merge (repo -> user) with preserve and inline JSONC comments =====
strip_jsonc_to_json(){ sed -e 's://.*$::' -e '/\/\*/,/\*\//d' "$1"; }

install_settings_from_repo(){
  [ -f "$REPO_SETTINGS_SRC" ] || { log "no repo settings.json; skipping settings merge"; return 0; }
  command -v jq >/dev/null 2>&1 || { warn "jq not available; skipping settings merge"; return 0; }

  ensure_dir "$USER_DIR"; ensure_dir "$STATE_DIR"

  tmp_user_json="$(mktemp)"
  if [ ! -f "$SETTINGS_PATH" ] || ! jq -e . "$SETTINGS_PATH" >/dev/null 2>&1; then
    if [ -f "$SETTINGS_PATH" ]; then strip_jsonc_to_json "$SETTINGS_PATH" >"$tmp_user_json" || printf '{}\n' >"$tmp_user_json"; else printf '{}\n' >"$tmp_user_json"; fi
  else
    cp "$SETTINGS_PATH" "$tmp_user_json"
  fi
  jq -e . "$tmp_user_json" >/dev/null 2>&1 || printf '{}\n' >"$tmp_user_json"

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
      | (delKeys($user; minus($oldkeys; $rskeys))) as $tmp_user
      | (delKeys($tmp_user; $rskeys)) as $user_without_repo
      | reduce $rskeys[] as $k (
          $user_without_repo;
          .[$k] = ( if ($pres | index($k)) and ($user | has($k)) then $user[$k] else $repo[$k] end )
        )
      | .gitstrap_preserve = arr($pres)
    ' "$tmp_user_json" > "$tmp_merged"

  tmp_managed="$(mktemp)"
  jq \
    --argjson ks "$RS_KEYS_JSON" '
      . as $src
      | reduce $ks[] as $k ({}; if $src | has($k) then .[$k] = $src[$k] else . end)
    ' "$tmp_merged" > "$tmp_managed"

  tmp_rest="$(mktemp)"
  jq --argjson ks "$RS_KEYS_JSON" '
    def delKeys($o;$ks): reduce $ks[] as $k ($o; del(.[$k]));
    delKeys(.; ($ks + ["gitstrap_preserve"]))
  ' "$tmp_merged" > "$tmp_rest"

  preserve_json="$(jq -c '.gitstrap_preserve // []' "$tmp_merged")"
  mcount="$(jq 'keys|length' "$tmp_managed")"
  rcount="$(jq 'keys|length' "$tmp_rest")"

  {
    echo "{"
    echo "  // START gitstrap settings"
    if [ "$mcount" -gt 0 ]; then
      jq -r '
        to_entries
        | map("  " + (.key|@json) + ": " + (.value|tojson))
        | join(",\n")
      ' "$tmp_managed"
      echo ","
    fi
    echo "  // gitstrap_preserve - enter key names of gitstrap merged settings here which you wish the gitstrap script not to overwrite"
    printf '  "gitstrap_preserve": %s\n' "$preserve_json"
    if [ "$rcount" -gt 0 ]; then
      echo "  // END gitstrap settings,"
      jq -r '
        to_entries
        | map("  " + (.key|@json) + ": " + (.value|tojson))
        | join(",\n")
      ' "$tmp_rest"
    else
      echo "  // END gitstrap settings"
    fi
    echo "}"
  } > "$SETTINGS_PATH"

  chown "${PUID}:${PGID}" "$SETTINGS_PATH" 2>/dev/null || true
  printf "%s" "$RS_KEYS_JSON" > "$MANAGED_KEYS_FILE"; chown "${PUID}:${PGID}" "$MANAGED_KEYS_FILE" 2>/dev/null || true

  rm -f "$tmp_user_json" "$tmp_merged" "$tmp_managed" "$tmp_rest" 2>/dev/null || true
  log "merged settings.json → $SETTINGS_PATH"
}

# ===== workspace config-shortcuts (symlinks in WORKSPACE_DIR only) =====
install_config_shortcuts(){
  local d="$WORKSPACE_DIR/config-shortcuts"
  ensure_dir "$d"
  [ -f "$SETTINGS_PATH" ]   || printf '{}\n' >"$SETTINGS_PATH"
  [ -f "$TASKS_PATH" ]      || printf '{}\n' >"$TASKS_PATH"
  [ -f "$KEYB_PATH" ]       || printf '[]\n' >"$KEYB_PATH"
  [ -f "$EXT_PATH" ]        || printf '{}\n' >"$EXT_PATH"

  mklink(){ src="$1"; dst="$2"; rm -f "$dst" 2>/dev/null || true; ln -s "$src" "$dst" 2>/dev/null || cp -f "$src" "$dst"; }

  mklink "$SETTINGS_PATH" "$d/settings.json"
  mklink "$TASKS_PATH"    "$d/tasks.json"
  mklink "$KEYB_PATH"     "$d/keybindings.json"
  mklink "$EXT_PATH"      "$d/extensions.json"

  chown -h "$PUID:$PGID" "$d" "$d/"* 2>/dev/null || true
  log "created config-shortcuts in workspace"
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
  echo "${GITSTRAP_VERSION:-0.3.2}" >/etc/gitstrap-version 2>/dev/null || true
}

bootstrap_banner(){ if has_tty; then printf "\n[gitstrap] Interactive bootstrap — press Ctrl+C to abort.\n\n" >/dev/tty; else log "No TTY; use flags or --env."; fi; }

bootstrap_interactive(){
  bootstrap_banner
  GH_USERNAME="${GH_USERNAME:-$(prompt_def "GitHub username: " "")}"; ORIGIN_GH_USERNAME="${ORIGIN_GH_USERNAME:-prompt}"
  [ -n "${GH_PAT:-}" ] || { GH_PAT="$(prompt_secret "GitHub PAT (classic: user:email, admin:public_key): ")"; ORIGIN_GH_PAT="${ORIGIN_GH_PAT:-prompt}"; }
  GIT_NAME="$(prompt_def "Git name [${GIT_NAME:-$GH_USERNAME}]: " "${GIT_NAME:-$GH_USERNAME}")"
  GIT_EMAIL="$(prompt_def "Git email (blank=auto resolve GH email): " "${GIT_EMAIL:-}")"
  GH_REPOS="$(prompt_def "Repos (comma-separated owner/repo[#branch]): " "${GH_REPOS:-}")"
  PULL_EXISTING_REPOS="$(yn_to_bool "$(prompt_def "Pull existing repos? [Y/n]: " "y")")"
  [ -n "${GH_USERNAME:-}" ] || { echo "GH_USERNAME or --gh-username required." >&2; exit 2; }
  [ -n "${GH_PAT:-}" ]     || { echo "GH_PAT or --gh-pat required." >&2; exit 2; }
  export GH_USERNAME GH_PAT GIT_NAME GIT_EMAIL GH_REPOS PULL_EXISTING_REPOS ORIGIN_GH_USERNAME ORIGIN_GH_PAT
  gitstrap_run; log "bootstrap complete"
}

bootstrap_env_only(){
  ORIGIN_GH_USERNAME="${ORIGIN_GH_USERNAME:-env GH_USERNAME}"
  ORIGIN_GH_PAT="${ORIGIN_GH_PAT:-env GH_PAT}"
  [ -n "${GH_USERNAME:-}" ] || { echo "GH_USERNAME or --gh-username required (env)." >&2; exit 2; }
  [ -n "${GH_PAT:-}" ]     || { echo "GH_PAT or --gh-pat required (env)." >&2; exit 2; }
  export ORIGIN_GH_USERNAME ORIGIN_GH_PAT
  gitstrap_run; log "bootstrap complete (env)"
}

# ===== flag → env mapping (1:1, dash/underscore agnostic) =====
ALLOWED_FLAG_VARS="GH_USERNAME GH_PAT GIT_NAME GIT_EMAIL GH_REPOS PULL_EXISTING_REPOS WORKSPACE_DIR REPOS_SUBDIR"
set_flag_env(){ # $1=flag key (already without leading --), $2=value
  norm="$(printf "%s" "$1" | tr '[:upper:]' '[:lower:]' | sed 's/-/_/g')"
  envname="$(printf "%s" "$norm" | tr '[:lower:]' '[:upper:]')"
  case " $ALLOWED_FLAG_VARS " in
    *" $envname "*)
      eval "export $envname=\$2"
      [ "$envname" = "GH_USERNAME" ] && ORIGIN_GH_USERNAME="--gh-username"
      [ "$envname" = "GH_PAT" ] && ORIGIN_GH_PAT="--gh-pat"
      export ORIGIN_GH_USERNAME ORIGIN_GH_PAT
      ;;
    *) warn "Unknown or disallowed flag '--$1'"; print_help; exit 1;;
  esac
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

bootstrap_from_args(){
  USE_ENV=false
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)     print_help; exit 0;;
      -v|--version)  print_version; exit 0;;
      --env)         USE_ENV=true;;
      settings-merge) install_settings_from_repo; install_config_shortcuts; exit 0;;
      passwd)        password_change_interactive; exit 0;;
      --*)
        key="${1#--}"; shift || true
        val="${1:-}"
        [ -n "$val" ] && [ "${val#--}" = "$val" ] || { warn "Flag '--$key' requires a value."; exit 2; }
        set_flag_env "$key" "$val"
        ;;
      *)
        warn "Unknown argument: $1"; print_help; exit 1;;
    esac
    shift || true
  done

  recompute_base

  if [ "$USE_ENV" = "true" ]; then
    ORIGIN_GH_USERNAME="${ORIGIN_GH_USERNAME:-env GH_USERNAME}"
    ORIGIN_GH_PAT="${ORIGIN_GH_PAT:-env GH_PAT}"
  else
    if ! is_tty; then
      echo "No TTY available for prompts. Use flags or --env. Examples:
  GH_USERNAME=alice GH_PAT=ghp_xxx gitstrap --env
  gitstrap --gh-username alice --gh-pat ghp_xxx --gh-repos \"alice/app#main\"
" >&2
      exit 3
    fi
    bootstrap_banner
    GH_USERNAME="${GH_USERNAME:-$(prompt_def "GitHub username: " "")}"; ORIGIN_GH_USERNAME="${ORIGIN_GH_USERNAME:-prompt}"
    [ -n "${GH_PAT:-}" ] || { GH_PAT="$(prompt_secret "GitHub PAT (classic: user:email, admin:public_key): ")"; ORIGIN_GH_PAT="${ORIGIN_GH_PAT:-prompt}"; }
    GIT_NAME="$(prompt_def "Git name [${GIT_NAME:-${GH_USERNAME:-}}]: " "${GIT_NAME:-${GH_USERNAME:-}}")"
    GIT_EMAIL="$(prompt_def "Git email (blank=auto): " "${GIT_EMAIL:-}")"
    GH_REPOS="$(prompt_def "Repos (comma-separated owner/repo[#branch]): " "${GH_REPOS:-}")"
    PULL_EXISTING_REPOS="$(yn_to_bool "$(prompt_def "Pull existing repos? [Y/n]: " "y")")"
  fi

  [ -n "${GH_USERNAME:-}" ] || { echo "GH_USERNAME or --gh-username required (flag/env/prompt)." >&2; exit 2; }
  [ -n "${GH_PAT:-}" ]     || { echo "GH_PAT or --gh-pat required (flag/env/prompt)." >&2; exit 2; }

  export GH_USERNAME GH_PAT GIT_NAME GIT_EMAIL GH_REPOS PULL_EXISTING_REPOS BASE WORKSPACE_DIR REPOS_SUBDIR ORIGIN_GH_USERNAME ORIGIN_GH_PAT
  gitstrap_run
  log "bootstrap complete"
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
    --env)        bootstrap_env_only; exit 0;;
    passwd)       password_change_interactive; exit 0;;
    settings-merge) install_settings_from_repo; install_config_shortcuts; exit 0;;
    *)            bootstrap_from_args "$@";;
  esac
}

# ===== autorun at container start (env-driven) =====
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

# ===== entrypoint =====
case "${1:-init}" in
  init)
    install_restart_gate
    install_cli_shim
    init_default_password
    install_settings_from_repo
    install_config_shortcuts
    autorun_env_if_present
    log "Gitstrap initialized. Use: gitstrap -h"
    ;;
  cli)
    shift; cli_entry "$@";;
  *)
    if [ $# -gt 0 ]; then set -- cli "$@"; exec "$0" "$@"; else set -- init; exec "$0" "$@"; fi
    ;;
esac
