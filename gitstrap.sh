#!/usr/bin/env sh
set -eu

# ========= core utils =========
log(){ echo "[gitstrap] $*"; }
warn(){ echo "[gitstrap][WARN] $*" >&2; }
redact(){ echo "$1" | sed 's/[A-Za-z0-9_\-]\{12,\}/***REDACTED***/g'; }

ensure_dir(){ mkdir -p "$1" 2>/dev/null || true; chown -R "$PUID:$PGID" "$1" 2>/dev/null || true; }
write_file(){ printf "%s" "$2" > "$1"; chown "$PUID:$PGID" "$1" 2>/dev/null || true; }

# temp file in same dir (avoid inter-device mv Permission denied)
mktemp_in_dir(){
  dir="$(dirname "$1")"; base="$(basename "$1")"
  ensure_dir "$dir"
  mktemp "${dir}/${base}.XXXXXX"
}

# ========= env / paths =========
export HOME="${HOME:-/config}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

USER_DIR="$HOME/data/User"
TASKS_PATH="$USER_DIR/tasks.json"
KEYB_PATH="$USER_DIR/keybindings.json"
SETTINGS_PATH="$USER_DIR/settings.json"

REPO_SETTINGS_SRC="$HOME/gitstrap/settings.json"

STATE_DIR="$HOME/.gitstrap"
MANAGED_KEYS_FILE="$STATE_DIR/managed-settings-keys.json"

BASE="${GIT_BASE_DIR:-$HOME/workspace}"
SSH_DIR="$HOME/.ssh"
KEY_NAME="id_ed25519"
PRIVATE_KEY_PATH="$SSH_DIR/$KEY_NAME"
PUBLIC_KEY_PATH="$SSH_DIR/${KEY_NAME}.pub"

LOCK_DIR="/run/gitstrap"
LOCK_FILE="$LOCK_DIR/init-gitstrap.lock"; mkdir -p "$LOCK_DIR" 2>/dev/null || true

# file that code-server reads on boot for auth (compose sets FILE__HASHED_PASSWORD)
PASS_HASH_PATH="${FILE__HASHED_PASSWORD:-$STATE_DIR/codepass.hash}"
# first-boot restart marker (processed by restart gate service)
FIRSTBOOT_MARKER="$STATE_DIR/.firstboot-auth-restart"

GITSTRAP_FLAG='__gitstrap_settings'

# ========= bool normalize =========
normalize_bool(){
  v="${1:-true}"; v="$(printf "%s" "$v" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  first="$(printf '%s' "$v" | cut -c1 | tr '[:upper:]' '[:lower:]')"
  if [ "$first" = "t" ]; then echo "true"
  elif [ "$first" = "f" ]; then echo "false"
  else echo "true"; fi
}

# ========= restart gate (install s6 service + tiny HTTP) =========
install_restart_gate(){
  NODE_BIN=""
  for p in /usr/local/bin/node /usr/bin/node /app/code-server/lib/node /usr/lib/code-server/lib/node; do
    if [ -x "$p" ]; then NODE_BIN="$p"; break; fi
  done
  if [ -z "${NODE_BIN:-}" ]; then warn "Node not found; restart gate disabled"; return 0; fi

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
srv.listen(PORT, HOST, ()=>console.log(`[restartgate] listening on ${HOST}:${PORT} (/restart to restart, /health no-op)`));
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

  cat >/etc/services.d/restartgate/finish <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
  chmod +x /etc/services.d/restartgate/finish

  log "installed restart gate service (Node) on 127.0.0.1:9000"
}

# ========= default password (first boot only) =========
init_default_password(){
  DEFAULT_PASSWORD="${DEFAULT_PASSWORD:-}"
  [ -n "$DEFAULT_PASSWORD" ] || { log "DEFAULT_PASSWORD not set; skipping default hash"; return 0; }
  if [ -s "$PASS_HASH_PATH" ]; then log "hash already present at $PASS_HASH_PATH; leaving as-is"; return 0; fi

  tries=0
  until command -v argon2 >/dev/null 2>&1; do
    tries=$((tries+1)); [ $tries -ge 20 ] && { warn "argon2 not found; cannot set default hash"; return 0; }
    sleep 1
  done

  ensure_dir "$(dirname "$PASS_HASH_PATH")"
  salt="$(head -c16 /dev/urandom | base64)"
  hash="$(printf '%s' "$DEFAULT_PASSWORD" | argon2 "$salt" -id -e)"
  printf '%s' "$hash" > "$PASS_HASH_PATH"
  chmod 644 "$PASS_HASH_PATH" || true
  chown "$PUID:$PGID" "$PASS_HASH_PATH" 2>/dev/null || true

  head="$(printf '%s' "$hash" | cut -c1-24)"
  log "wrote initial Argon2 hash to $PASS_HASH_PATH (head=${head}...)"
  ensure_dir "$(dirname "$FIRSTBOOT_MARKER")"; : > "$FIRSTBOOT_MARKER"
  log "queued first-boot restart via marker: $FIRSTBOOT_MARKER"
}

# ========= password helpers =========
ensure_argon2(){
  tries=0
  until command -v argon2 >/dev/null 2>&1; do
    tries=$((tries+1)); [ $tries -ge 10 ] && { echo "Error: argon2 CLI not found." >&2; return 1; }
    sleep 0.5
  done
  return 0
}
trigger_restart_gate(){
  if command -v curl >/dev/null 2>&1; then
    if curl -fsS --max-time 3 "http://127.0.0.1:9000/restart" >/dev/null 2>&1; then
      log "restart gate responded at 127.0.0.1:9000/restart"
    else
      warn "restart trigger failed (cannot reach 127.0.0.1:9000)"
    fi
  else
    warn "curl not found; please restart the container manually"
  fi
}
apply_password_hash(){
  NEW="$1"; CONF="$2"
  [ -n "$NEW" ]  || { echo "Error: password is required." >&2; return 1; }
  [ -n "$CONF" ] || { echo "Error: confirmation is required." >&2; return 1; }
  [ "$NEW" = "$CONF" ] || { echo "Error: passwords do not match." >&2; return 1; }
  [ ${#NEW} -ge 8 ] || { echo "Error: password must be at least 8 characters." >&2; return 1; }

  ensure_dir "$STATE_DIR"; ensure_argon2 || return 1
  salt="$(head -c16 /dev/urandom | base64)"
  hash="$(printf '%s' "$NEW" | argon2 "$salt" -id -e)"
  printf '%s' "$hash" > "$PASS_HASH_PATH"
  chmod 644 "$PASS_HASH_PATH" || true
  chown "$PUID:$PGID" "$PASS_HASH_PATH" 2>/dev/null || true
  sync || true

  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  size="$(wc -c < "$PASS_HASH_PATH" 2>/dev/null || echo 0)"
  head="$(cut -c1-22 < "$PASS_HASH_PATH" 2>/dev/null || true)"
  log "hashed password saved to $PASS_HASH_PATH (utc=$ts bytes=$size head=${head}...)"

  # ===== big visible banner =====
  printf "\n\033[1;33m*** CODE-SERVER PASSWORD CHANGED ***\n*** REFRESH PAGE TO LOGIN ***\033[0m\n\n"

  log "container will restart; code-server will read FILE__HASHED_PASSWORD."
  trigger_restart_gate
  return 0
}
codepass_set(){ apply_password_hash "${1:-}" "${2:-}"; exit 0; }
maybe_apply_password_from_env(){
  if [ -n "${NEW_PASSWORD:-}" ] || [ -n "${CONFIRM_PASSWORD:-}" ]; then
    apply_password_hash "${NEW_PASSWORD:-}" "${CONFIRM_PASSWORD:-}" || true
  fi
}

# ========= VS Code assets (single task + inputs) =========
install_user_assets(){
  ensure_dir "$USER_DIR"

  GITSTRAP_TASK='{
    "__gitstrap_settings": true,
    "label": "Bootstrap GitHub Workspace",
    "type": "shell",
    "command": "sh",
    "args": ["/custom-cont-init.d/10-gitstrap.sh","force"],
    "options": {
      "env": {
        "GH_USERNAME": "${input:gh_username}",
        "GH_PAT": "${input:gh_pat}",
        "GH_PAT_FALLBACK": "${env:GH_PAT}",
        "GIT_EMAIL": "${input:git_email}",
        "GIT_NAME": "${input:git_name}",
        "GH_REPOS": "${input:gh_repos}",
        "PULL_EXISTING_REPOS": "${input:pull_existing_repos}",
        "NEW_PASSWORD": "${input:new_password}",
        "CONFIRM_PASSWORD": "${input:confirm_password}"
      }
    },
    "problemMatcher": [],
    "gitstrap_preserve": []
  }'

  INPUTS_JSON='[
    { "__gitstrap_settings": true, "id": "gh_username",   "type": "promptString", "description": "GitHub username (required)", "default": "${env:GH_USERNAME}", "gitstrap_preserve": [] },
    { "__gitstrap_settings": true, "id": "gh_pat",    "type": "promptString", "description": "GitHub PAT (classic; scopes: user:email, admin:public_key). Leave blank to use env var GH_PAT if set.", "password": true, "gitstrap_preserve": [] },
    { "__gitstrap_settings": true, "id": "git_email", "type": "promptString", "description": "Git email (optional; leave empty to auto-detect github email)", "default": "${env:GIT_EMAIL}", "gitstrap_preserve": [] },
    { "__gitstrap_settings": true, "id": "git_name",  "type": "promptString", "description": "Git name (optional; leave empty to use github username)", "default": "${env:GIT_NAME}", "gitstrap_preserve": [] },
    { "__gitstrap_settings": true, "id": "gh_repos", "type": "promptString", "description": "Repos to clone (owner/repo or owner/repo#specific-branch or URL, comma-separated)", "default": "${env:GH_REPOS}", "gitstrap_preserve": [] },
    { "__gitstrap_settings": true, "id": "pull_existing_repos", "type": "promptString", "description": "Pull existing repos if already cloned? (true/false, t/f, etc.)", "default": "${env:PULL_EXISTING_REPOS}", "gitstrap_preserve": [] },
    { "__gitstrap_settings": true, "id": "new_password",     "type": "promptString", "description": "Enter a NEW code-server password (leave blank to skip)", "password": true, "gitstrap_preserve": [] },
    { "__gitstrap_settings": true, "id": "confirm_password", "type": "promptString", "description": "Confirm the NEW password (leave blank to skip)", "password": true, "gitstrap_preserve": [] }
  ]'

  KB_G='{
    "__gitstrap_settings": true,
    "key": "ctrl+alt+g",
    "command": "workbench.action.tasks.runTask",
    "args": "Bootstrap GitHub Workspace",
    "gitstrap_preserve": []
  }'

  # normalize bad keybindings → array
  if [ -f "$KEYB_PATH" ] && command -v jq >/dev/null 2>&1; then
    tmp="$(mktemp_in_dir "$KEYB_PATH")"
    if ! jq -e . "$KEYB_PATH" >/dev/null 2>&1; then
      cp "$KEYB_PATH" "$KEYB_PATH.bak" 2>/dev/null || true
      printf '[]' > "$KEYB_PATH"
    else
      jq 'if type=="array" then . else [] end' "$KEYB_PATH" > "$tmp" && mv -f "$tmp" "$KEYB_PATH"
    fi
    chown "$PUID:$PGID" "$KEYB_PATH" 2>/dev/null || true
  fi

  if command -v jq >/dev/null 2>&1; then
    # ---- tasks.json upsert (ONE task) with guards + prune old flagged tasks
    tmp_tasks="$(mktemp_in_dir "$TASKS_PATH")"
    if [ -f "$TASKS_PATH" ] && jq -e . "$TASKS_PATH" >/dev/null 2>&1; then
      jq \
        --arg flag "$GITSTRAP_FLAG" \
        --argjson task "$GITSTRAP_TASK" '
          def ensureObj(o): if (o|type)=="object" then o else {} end;
          def ensureArr(a): if (a|type)=="array"  then a else [] end;
          def merge_with_preserve($old; $incoming; $flag):
            ($incoming + {($flag): true})
            | ( .gitstrap_preserve = ( (($old.gitstrap_preserve // []) + (.gitstrap_preserve // [])) | unique ) )
            | ( reduce (($old.gitstrap_preserve // [])[]) as $k (. ; .[$k] = ($old[$k] // .[$k]) ) )
          ;

          (ensureObj(.)) as $root
          | ($root.tasks // []) as $tasks_raw
          | (ensureArr($tasks_raw)) as $tasks
          | ($tasks | map(select(type=="object"))) as $objs
          | ($tasks | map(select(type!="object"))) as $nonobjs
          | .version = (.version // "2.0.0")

          # keep: unflagged + flagged that match our label; drop other flagged we manage
          | ($objs | map(
              if ((.[$flag]? // false)==true)
              then if ((.label? // "") == ($task.label // "")) then . else empty end
              else . end
            )) as $kept

          # upsert our one task by label
          | .tasks = (
              if any($kept[]?; (type=="object") and ((.[$flag]? // false)==true) and ((.label? // "")==($task.label // ""))) then
                ($kept | map(
                  if ( (type=="object") and ((.[$flag]? // false)==true) and ((.label? // "")==($task.label // "")) )
                  then merge_with_preserve(.; $task; $flag)
                  else .
                  end))
              else
                $kept + [ $task ]
              end
            ) + $nonobjs
        ' "$TASKS_PATH" > "$tmp_tasks" && mv -f "$tmp_tasks" "$TASKS_PATH"
    else
      printf '%s\n' "$(cat <<JSON
{
  "version": "2.0.0",
  "tasks": [ $GITSTRAP_TASK ],
  "inputs": []
}
JSON
)" > "$TASKS_PATH"
    fi

    # ---- inputs strict upsert by id; prune flagged unknown ids; guard non-objects
    tmp_tasks2="$(mktemp_in_dir "$TASKS_PATH")"
    jq \
      --arg flag "$GITSTRAP_FLAG" \
      --argjson newinputs "$INPUTS_JSON" '
        def ensureArr(a): if (a|type)=="array" then a else [] end;
        def merge_with_preserve($old; $incoming; $flag):
          ($incoming + {($flag): true})
          | ( .gitstrap_preserve = ( (($old.gitstrap_preserve // []) + (.gitstrap_preserve // [])) | unique ) )
          | ( reduce (($old.gitstrap_preserve // [])[]) as $k (. ; .[$k] = ($old[$k] // .[$k]) ) )
        ;

        (.inputs // []) as $cur_raw
        | (ensureArr($cur_raw)) as $cur
        | ($cur | map(select(type=="object"))) as $objs
        | ($cur | map(select(type!="object"))) as $nonobjs
        | ($newinputs | map(select(.id? != null) | .id) | unique) as $ids

        # drop flagged inputs we no longer manage
        | ($objs | map(
            if ((.[$flag]? // false)==true) and (($ids | index(.id? // "")) | not)
            then empty else . end
          )) as $kept

        # upsert each desired input by id
        | .inputs = (
            reduce $newinputs[] as $inc (
              $kept;
              ($inc.id // "") as $id
              | if $id == "" then .
                else
                  if any(.[]?; (type=="object") and ((.id? // "")==$id)) then
                    map( if ( (type=="object") and ((.id? // "")==$id) )
                         then ( if ((.[$flag]? // false)==true) then merge_with_preserve(.; $inc; $flag) else $inc end )
                         else . end )
                  else . + [ $inc ] end
                end
            ) + $nonobjs
          )
      ' "$TASKS_PATH" > "$tmp_tasks2" && mv -f "$tmp_tasks2" "$TASKS_PATH"

    # ---- keybindings.json upsert (only Ctrl+Alt+G) + remove old password binding if present
    tmp_kb="$(mktemp_in_dir "$KEYB_PATH")"
    if [ -f "$KEYB_PATH" ] && jq -e . "$KEYB_PATH" >/dev/null 2>&1; then
      jq \
        --arg flag "$GITSTRAP_FLAG" \
        --argjson nk "$KB_G" '
          def ensureArr(a): if (a|type)=="array" then a else [] end;
          def merge_with_preserve($old; $incoming; $flag):
            ($incoming + {($flag): true})
            | ( .gitstrap_preserve = ( (($old.gitstrap_preserve // []) + (.gitstrap_preserve // [])) | unique ) )
            | ( reduce (($old.gitstrap_preserve // [])[]) as $k (. ; .[$k] = ($old[$k] // .[$k]) ) )
          ;

          (ensureArr(.)) as $arr
          | ($arr | map(select(type=="object"))) as $objs
          | ($arr | map(select(type!="object"))) as $nonobjs

          # remove any old flagged binding pointing to the old password task
          | ($objs | map(
              if ((.[$flag]? // false)==true
                  and (.command? // "")=="workbench.action.tasks.runTask"
                  and (.args? // "")=="Change code-server password")
              then empty else . end
            )) as $clean

          # upsert Ctrl+Alt+G binding by (command,args,key)
          | ( if any($clean[]?; (type=="object")
                                and (.command? // "")==($nk.command // "")
                                and (.args? // "")==($nk.args // "")
                                and (.key? // "")==($nk.key // "")) then
                ( $clean | map(
                    if ( (type=="object")
                         and (.command? // "")==($nk.command // "")
                         and (.args? // "")==($nk.args // "")
                         and (.key? // "")==($nk.key // "") )
                    then ( if ((.[$flag]? // false)==true) then merge_with_preserve(.; $nk; $flag) else $nk end )
                    else . end ))
              else
                $clean + [ $nk ]
              end
            ) + $nonobjs
        ' "$KEYB_PATH" > "$tmp_kb" && mv -f "$tmp_kb" "$KEYB_PATH"
    else
      printf '[%s]\n' "$KB_G" > "$KEYB_PATH"
    fi
  else
    # no jq → create-only
    [ -f "$TASKS_PATH" ] || printf '%s\n' "$(cat <<JSON
{
  "version": "2.0.0",
  "tasks": [ $GITSTRAP_TASK ],
  "inputs": $INPUTS_JSON
}
JSON
)" > "$TASKS_PATH"
    [ -f "$KEYB_PATH" ] || printf '[%s]\n' "$KB_G" > "$KEYB_PATH"
  fi

  chown "$PUID:$PGID" "$TASKS_PATH" "$KEYB_PATH" 2>/dev/null || true
  log "installed/merged single task, inputs, and keybindings"
}

# ========= settings merge (repo -> user) with preserve =========
install_settings_from_repo(){
  [ -f "$REPO_SETTINGS_SRC" ] || { log "no repo settings.json; skipping settings merge"; return 0; }
  if ! command -v jq >/dev/null 2>&1; then
    if [ ! -f "$SETTINGS_PATH" ]; then
      ensure_dir "$USER_DIR"
      write_file "$SETTINGS_PATH" '{
        "__gitstrap_settings": true,
        "gitstrap_preserve": []
      }'
    fi
    return 0
  fi
  if ! jq -e . "$REPO_SETTINGS_SRC" >/dev/null 2>&1; then warn "repo settings JSON invalid → $REPO_SETTINGS_SRC ; skipping"; return 0; fi

  ensure_dir "$STATE_DIR"; ensure_dir "$USER_DIR"

  if [ -f "$SETTINGS_PATH" ]; then
    tmp_norm="$(mktemp_in_dir "$SETTINGS_PATH")"
    if ! jq -e . "$SETTINGS_PATH" >/dev/null 2>&1; then
      cp "$SETTINGS_PATH" "$SETTINGS_PATH.bak" 2>/dev/null || true
      printf "{}" > "$SETTINGS_PATH"
    else
      jq 'if type=="object" then . else {} end' "$SETTINGS_PATH" > "$tmp_norm" && mv -f "$tmp_norm" "$SETTINGS_PATH"
    fi
  else
    printf "{}" > "$SETTINGS_PATH"; chown "$PUID:$PGID" "$SETTINGS_PATH" 2>/dev/null || true
  fi

  RS_KEYS_JSON="$(jq 'keys' "$REPO_SETTINGS_SRC")"
  if [ -f "$MANAGED_KEYS_FILE" ] && jq -e . "$MANAGED_KEYS_FILE" >/dev/null 2>&1; then
    OLD_KEYS_JSON="$(cat "$MANAGED_KEYS_FILE")"
  else
    OLD_KEYS_JSON='[]'
  fi

  tmp_out="$(mktemp_in_dir "$SETTINGS_PATH")"
  jq \
    --arg flag "$GITSTRAP_FLAG" \
    --argjson repo "$(cat "$REPO_SETTINGS_SRC")" \
    --argjson rskeys "$RS_KEYS_JSON" \
    --argjson oldkeys "$OLD_KEYS_JSON" '
      def minus($a; $b): [ $a[] | select( ($b | index(.)) | not ) ];
      def delKeys($obj; $ks): reduce $ks[] as $k ($obj; del(.[$k]));
      (. // {}) as $user
      | ($user.gitstrap_preserve // []) as $pres
      | (delKeys($user; minus($oldkeys; $rskeys))) as $tmp_user
      | (delKeys($tmp_user; $rskeys)) as $user_without_repo
      | ($user_without_repo | to_entries) as $ents
      | reduce $ents[] as $e ({}; .[$e.key] = $e.value)
      | .["__gitstrap_settings"] = true
      | .["gitstrap_preserve"]  = $pres
      | ( reduce $rskeys[] as $k
            ( . ;
              .[$k] = ( if ($pres | index($k)) and ($user | has($k)) then $user[$k] else $repo[$k] end )
            )
        )
  ' "$SETTINGS_PATH" > "$tmp_out" && mv -f "$tmp_out" "$SETTINGS_PATH"
  chown "$PUID:$PGID" "$SETTINGS_PATH" 2>/dev/null || true
  printf "%s" "$RS_KEYS_JSON" > "$MANAGED_KEYS_FILE"; chown "$PUID:$PGID" "$MANAGED_KEYS_FILE" 2>/dev/null || true

  log "merged settings.json → $SETTINGS_PATH"
}

# ========= github bootstrap =========
resolve_email(){
  EMAILS="$(curl -fsS -H "Authorization: token ${GH_PAT}" -H "Accept: application/vnd.github+json" https://api.github.com/user/emails || true)"
  PRIMARY="$(printf "%s" "$EMAILS" | awk -F\" '/"email":/ {e=$4} /"primary": *true/ {print e; exit}')"
  [ -n "${PRIMARY:-}" ] && { echo "$PRIMARY"; return; }
  VERIFIED="$(printf "%s" "$EMAILS" | awk -F\" '/"email":/ {e=$4} /"verified": *true/ {print e; exit}')"
  [ -n "${VERIFIED:-}" ] && { echo "$VERIFIED"; return; }
  PUB_JSON="$(curl -fsS -H "Accept: application/vnd.github+json" "https://api.github.com/users/${GH_USERNAME}" || true)"
  PUB_EMAIL="$(printf "%s" "$PUB_JSON" | awk -F\" '/"email":/ {print $4; exit}')"
  [ -n "${PUB_EMAIL:-}" ] && [ "$PUB_EMAIL" != "null" ] && { echo "$PUB_EMAIL"; return; }
  echo "${GH_USERNAME}@users.noreply.github.com"
}
do_gitstrap(){
  : "${GH_USERNAME:?GH_USERNAME is required}"
  : "${GH_PAT:?GH_PAT is required}"

  GIT_NAME="${GIT_NAME:-$GH_USERNAME}"
  GH_REPOS="${GH_REPOS:-}"
  PULL_EXISTING_BOOL="$(normalize_bool "${PULL_EXISTING_REPOS:-true}")"

  log "gitstrap: user=$GH_USERNAME, name=$GIT_NAME, base=$BASE, pull_existing_repos=$PULL_EXISTING_BOOL"
  mkdir -p "$BASE" && chown -R "$PUID:$PGID" "$BASE" || true

  git config --global init.defaultBranch main || true
  git config --global pull.ff only || true
  git config --global advice.detachedHead false || true
  git config --global --add safe.directory "*"

  git config --global user.name "$GIT_NAME" || true
  if [ -z "${GIT_EMAIL:-}" ]; then GIT_EMAIL="$(resolve_email || true)"; fi
  git config --global user.email "$GIT_EMAIL" || true
  log "identity: $GIT_NAME <$GIT_EMAIL>"

  umask 077
  mkdir -p "$SSH_DIR" && chown -R "$PUID:$PGID" "$SSH_DIR"; chmod 700 "$SSH_DIR"

  if [ ! -f "$PRIVATE_KEY_PATH" ]; then
    log "Generating SSH key"
    ssh-keygen -t ed25519 -f "$PRIVATE_KEY_PATH" -N "" -C "${GIT_EMAIL:-git@github.com}"
    chmod 600 "$PRIVATE_KEY_PATH"; chmod 644 "$PUBLIC_KEY_PATH"
  else
    log "SSH key exists; skipping"
  fi

  touch "$SSH_DIR/known_hosts"; chmod 644 "$SSH_DIR/known_hosts"; chown "$PUID:$PGID" "$SSH_DIR/known_hosts"
  if command -v ssh-keyscan >/dev/null 2>&1 && ! grep -q "^github.com" "$SSH_DIR/known_hosts" 2>/dev/null; then
    ssh-keyscan github.com >> "$SSH_DIR/known_hosts" 2>/dev/null || true
  fi

  git config --global core.sshCommand \
    "ssh -i $PRIVATE_KEY_PATH -F /dev/null -o IdentitiesOnly=yes -o UserKnownHostsFile=$SSH_DIR/known_hosts -o StrictHostKeyChecking=accept-new"

  LOCAL_KEY="$(awk '{print $1" "$2}' "$PUBLIC_KEY_PATH")"
  TITLE="${GH_KEY_TITLE:-Docker SSH Key}"
  KEYS_JSON="$(curl -fsS -H "Authorization: token ${GH_PAT}" -H "Accept: application/vnd.github+json" https://api.github.com/user/keys || true)"
  if echo "$KEYS_JSON" | grep -q "\"key\": *\"$LOCAL_KEY\""; then
    log "SSH key already on GitHub"
  else
    log "Uploading SSH key to GitHub"
    RESP="$(curl -fsS -X POST -H "Authorization: token ${GH_PAT}" -H "Accept: application/vnd.github+json" \
      -d "{\"title\":\"$TITLE\",\"key\":\"$LOCAL_KEY\"}" https://api.github.com/user/keys || true)"
    echo "$RESP" | grep -q '"id"' && log "SSH key added" || log "Key upload failed: $(redact "$RESP")"
  fi

  clone_one() {
    spec="$1"; [ -n "$spec" ] || return 0
    spec=$(echo "$spec" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'); [ -n "$spec" ] || return 0
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
      if [ "$PULL_EXISTING_BOOL" = "true" ]; then
        log "pull: ${name}"
        git -C "$dest" fetch --all -p || true
        if [ -n "$branch" ]; then
          git -C "$dest" checkout "$branch" || true
          git -C "$dest" reset --hard "origin/${branch}" || true
        else
          git -C "$dest" pull --ff-only || true
        fi
      else
        log "skip pull (PULL_EXISTING_REPOS=false): ${name}"
      fi
    else
      log "clone: ${safe_url} -> ${dest} (branch='\${branch:-default}')"
      if [ -n "$branch" ]; then
        git clone --branch "$branch" --single-branch "$url" "$dest" || { log "clone failed: $spec"; return 0; }
      else
        git clone "$url" "$dest" || { log "clone failed: $spec"; return 0; }
      fi
    fi
    chown -R "$PUID:$PGID" "$dest" || true
  }

  if [ -n "${GH_REPOS:-}" ]; then
    IFS=,; set -- $GH_REPOS; unset IFS
    for spec in "$@"; do clone_one "$spec"; done
  else
    log "GH_REPOS empty; skip clone"
  fi
  log "gitstrap done"
}

# ========= main phases =========
autorun_or_hint(){
  if [ -n "${GH_USERNAME:-}" ] && [ -n "${GH_PAT:-}" ] && [ ! -f "$LOCK_FILE" ]; then
    : > "$LOCK_FILE" || true
    log "env present and no lock → running gitstrap"
    do_gitstrap || true
  else
    [ -f "$LOCK_FILE" ] && log "init-gitstrap lock present → skipping duplicate gitstrap this start"
    { [ -z "${GH_USERNAME:-}" ] || [ -z "${GH_PAT:-}" ] ; } && log "GH_USERNAME/GH_PAT missing → skipping init gitstrap (use Ctrl+Alt+G inside code-server to gitstrap)"
  fi
}

# Coalesce runtime envs from task (let empty PAT fall back to container env)
resolve_task_env_fallbacks(){
  if [ -z "${GH_PAT:-}" ] && [ -n "${GH_PAT_FALLBACK:-}" ]; then
    export GH_PAT="$GH_PAT_FALLBACK"
  fi
}

init_all(){
  install_restart_gate
  init_default_password
  install_user_assets
  install_settings_from_repo
  autorun_or_hint
  log "Tasks, Keybindings, & Settings installed under: $USER_DIR"
}

ensure_assets_and_settings(){
  install_user_assets
  install_settings_from_repo
}

case "${1:-init}" in
  init)
    init_all
    ;;
  force)
    # Merge assets/settings first so prompts show correctly, then coalesce envs.
    ensure_assets_and_settings
    resolve_task_env_fallbacks
    if [ -n "${GH_USERNAME:-}" ] && [ -n "${GH_PAT:-}" ]; then
      do_gitstrap
    else
      log "GH_USERNAME or GH_PAT not provided → skipping repo bootstrap"
    fi
    maybe_apply_password_from_env
    ;;
  codepass)
    shift; [ "${1:-}" = "set" ] || { echo "Usage: $0 codepass set NEW CONFIRM" >&2; exit 1; }
    shift; codepass_set "${1:-}" "${2:-}"
    ;;
  settings-merge)  install_settings_from_repo ;;
  gate-install)    install_restart_gate ;;
  default-pass)    init_default_password ;;
  *)
    init_all
    ;;
esac
