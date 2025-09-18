# README

> **One-command, github integrated bootstrap for code-server**
>
> Ships a ready-to-work VS Code-in-the-browser environment that can:
>
> * Bootstraps your workspace with GitHub: generates an SSH key if not exists, uploads it to GitHub via a PAT if not exists, authorize code-server workspace with GitHub and clone/pull specified repos.
> * Installs a single, well‑behaved Task + Inputs and a single keybinding to run gitstrap (`ctrl+alt+g`) into your user profile without trampling your own edits and settings by using `__gitstrap_settings` and `gitstrap_preserve`.
> * Set a first‑boot password hash automatically (and let you change or set password from inside code-server).
> * Merges a predefined `settings.json` into your user `settings.json` with precise, reversible control using `__gitstrap_settings` and `gitstrap_preserve`.

This repository wraps the official LinuxServer.io `code-server` image with `gitstrap.sh` and a few conventions and niceties that make fresh environments productive in seconds.

---

## Contents

* [How it works (boot flow)](#how-it-works-boot-flow)
* [Quick start](#quick-start)
* [Environment variables](#environment-variables)
* [Ports & reverse proxy note](#ports--reverse-proxy-note)
* [The Gitstrap code-server Task & keybinding](#the-gitstrap-task--keybinding)
* [Changing the code-server password](#changing-the-code-server-password)
* [Settings merge, markers, and preservation](#settings-merge-markers-and-preservation)
* [Repository cloning syntax](#repository-cloning-syntax)
* [Volumes & persistence](#volumes--persistence)
* [Troubleshooting](#troubleshooting)
* [FAQ](#faq)

---

## How it works (boot flow)

1. **Restart gate** — `gitstrap.sh` installs a tiny supervised Node HTTP service at `127.0.0.1:9000` to request a *gentle container restart* after sensitive changes (like password updates).
2. **First‑boot password hash** — If `DEFAULT_PASSWORD` is set and no hash exists at `FILE__HASHED_PASSWORD`, a secure Argon2 hash is generated and saved. A one‑time marker triggers a supervised restart so code‑server picks it up.
3. **User assets** — A single VS Code **Task**, its **Inputs**, and a **keybinding** are installed/updated under `/config/data/User` with guard rails `__gitstrap_settings` and `gitstrap_preserve` to avoid stomping your own customizations.
4. **Settings merge** — If `./settings.json` exists in this repo (mounted into `/config/gitstrap/settings.json`), its keys are merged into your user `settings.json` under `__gitstrap_settings` key/val with explicit markers and preservation behavior using `gitstrap_preserve` (details below).
5. **Autorun on container create/recreate (optional)** — If both `GH_USERNAME` **and** `GH_PAT` are present, gitstrap runs automatically: generates SSH keys, uploads the public key to GitHub, and clones/pulls the repos you specify.
6. **Otherwise** — Launch code‑server and press **`ctrl+alt+g`** (or run the task from the Command Palette) to gitstrap on demand.

---

## Quick start

1. **Copy and edit desired env vars from** `.env.example` → `.env` (If you want to gitstrap on container create/recreate use env vars, otherwise if you desire to gitstrap from within code-server, no envs needed. Although, it is recommended to set DEFAULT_PASSWORD at minimum).
2. Review `docker-compose.yml` and adjust ports/volumes to your environment (see note on ports below).
3. `docker compose up -d`.
4. Open code‑server in your browser. If you didn’t set `GH_USERNAME` + `GH_PAT`, press **`ctrl+alt+g`** to run **“Gitstrap code-server”** and follow the prompts.

> You can leave all Git‑strap envs empty and fully bootstrap interactively inside code‑server.

---

## Environment variables

These are read by `docker-compose.yml` and/or the script. Defaults are sensible; everything is optional except where noted.

| Variable              | Required | Purpose                                                                                                                                                                                                                                        |
| --------------------- | :------: | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `TZ`                  |     ☐    | Container timezone (e.g., `America/Toronto`).                                                                                                                                                                                                  |
| `DEFAULT_PASSWORD`    |     ☐    | If set and no existing hash is present, an Argon2 hash is generated on first boot and saved to `FILE__HASHED_PASSWORD`.                                                                                                                        |
| `GH_USERNAME`         |     ☐    | **Use this** to enable **autorun** of gitstrap at container start (must be paired with `GH_PAT`). Used for Git identity defaults when `GIT_NAME`/`GIT_EMAIL` aren’t set.                                                                       |
| `GH_PAT`              |     ☐    | GitHub Personal Access Token (classic) with scopes `user:email, admin:public_key`. Used to upload the SSH key and resolve your primary email. If left empty during the Task, the Task will fall back to the container env `GH_PAT` if present. |
| `GIT_NAME`            |     ☐    | If provided, sets global `git config user.name`. Defaults to `GH_USERNAME` when not provided.                                                                                                                                                  |
| `GIT_EMAIL`           |     ☐    | If provided, sets global `git config user.email`. If omitted, the script resolves your primary/verified GitHub email via API, or falls back to `<username>@users.noreply.github.com`.                                                          |
| `PULL_EXISTING_REPOS` |     ☐    | `true`/`false` — when repos already exist locally, `true` makes gitstrap fetch/pull/reset to `origin/<branch>`; `false` leaves them untouched.                                                                                                 |
| `GH_REPOS`            |     ☐    | Comma‑separated list of repos to clone. Supports `owner/repo`, `owner/repo#branch`, full HTTPS/SSH URLs. See [Repository cloning syntax](#repository-cloning-syntax).                                                                          |
| `GIT_BASE_DIR`        |     ☐    | Workspace root inside the container. Defaults to `/config/workspace` (mapped to the `projects` volume).                                                                                                                                        |

---

## Ports & reverse proxy note

In `docker-compose.yml`, the port binding is shown as `":"8443"`. That means “expose container port 8443 on a host‑assigned random port.” This is useful when a reverse proxy (e.g., Traefik, nginx, or an orchestration layer) is managing inbound ports and TLS termination for you.

If you’re **not** using an external proxy and want a deterministic host port, change it to e.g.:

```yaml
ports:
  - "8443:8443"   # host:container
```

Pick a host port that works in your environment.

---

## The Gitstrap code-server Task & keybinding

On first run, the script installs/updates a **single** Task called **“Gitstrap code-server”** into your user profile at `/config/data/User/tasks.json`. It also defines **Inputs** for the Task’s prompts and a single keyboard shortcut in `/config/data/User/keybindings.json`.

* **Keybinding:** `ctrl+alt+g` → runs the Task.
* **Command Palette:** press `F1`, run **Tasks: Run Task**, select **“Gitstrap code-server.”**

### Task inputs

When you run the Task, you’ll be prompted for:

* **GitHub username** — `gh_username` (defaults from env `GH_USERNAME` if set)
* **GitHub PAT** — `gh_pat` (if left empty, the Task uses the container’s `GH_PAT` if set)
* **Git email** — `git_email` (optional; auto‑resolved if empty)
* **Git name** — `git_name` (optional; defaults to your GitHub username if empty)
* **Repos** — `gh_repos` (comma‑separated)
* **Pull existing repos?** — `pull_existing_repos` (`true`/`false`)
* **New password** — `new_password` (optional)
* **Confirm password** — `confirm_password` (optional)

> The Task updates your code‑server password **immediately** if both password prompts are provided and match; you’ll see a banner and the container will be restarted by the restart gate.

---

## Changing the code-server password

You have three options:

1. **First boot only** — Set `DEFAULT_PASSWORD` before first start. A secure Argon2 hash is written to `FILE__HASHED_PASSWORD`.
2. **From inside code-server** — Run **“Gitstrap code-server”** (`ctrl+alt+g`), fill **New/Confirm password**, and submit. The container will restart cleanly.
3. **Manual CLI** — Exec into the container (or via terminal in code-server) and run:

    ```bash
    gitstrap password set "newpass" "newpass"
    ```

    **OR**

    ```bash
    /custom-cont-init.d/10-gitstrap.sh password set "newpass" "newpass"
    ```

All methods write the hash to the path specified by the `FILE__HASHED_PASSWORD` env (already set in `docker-compose.yml`).

---

## Settings merge, markers, and preservation

Two simple mechanisms give you precision control over what the script manages and what you own.

### `__gitstrap_settings`

* The script tags any objects it writes with `"__gitstrap_settings": true`.
* In **user `settings.json`**, keys sourced from the repository’s `settings.json` are written below that marker so you can visually spot managed keys.

### `gitstrap_preserve`

Use the `gitstrap_preserve` array to **any** object the script manages (tasks, inputs, keybindings, settings). It lists the **keys** you want the script to leave alone on subsequent runs.

**Example — preserving your custom keybinding while keeping everything else managed:**

```jsonc
// /config/data/User/keybindings.json
[
  {
    "__gitstrap_settings": true,
    "key": "ctrl+alt+h",              // <- your own key
    "command": "workbench.action.tasks.runTask",
    "args": "Gitstrap code-server",
    "gitstrap_preserve": ["key"]     // <- tell Gitstrap to NOT overwrite `key`
  }
]
```

On the next run, the script updates the same object **but** keeps your `key` value because it’s listed under `gitstrap_preserve`.

**Example — preserving selected settings merged from the repo:**

```jsonc
// /config/data/User/settings.json
{
  "__gitstrap_settings": true,
  "gitstrap_preserve": [
    "workbench.colorTheme",            // keep my theme
    "editor.tabSize"                   // keep my tab size
  ],
  "workbench.colorTheme": "Solarized Light", // my override
  "editor.tabSize": 4,
  // ... other settings possibly written by the repo merge
}
```

On subsequent merges, if those keys were defined in gitstraps settings.json those keys retain your values.

> Under the hood, the script tracks the set of keys previously written from the repo in `/config/.gitstrap/managed-settings-keys.json` and carefully merges/removes only those keys, respecting your `gitstrap_preserve` list.

---

## Repository cloning syntax

Set `GH_REPOS` (env or task prompt) to a comma‑separated list. Each item supports:

* `owner/repo` → clones default branch via SSH (after your key is uploaded).
* `owner/repo#branch` → clones that branch only.
* Full URLs:

  * `https://github.com/owner/repo` or `.git`
  * `ssh://git@github.com/owner/repo.git`

Examples:

```
GH_REPOS="owner1/repo1#main, owner2/repo2, https://github.com/owner3/repo3"
```

When a target directory already contains a Git repo:

* If `PULL_EXISTING_REPOS=true`, gitstrap will `fetch --all -p` and fast‑forward pull, or hard reset to `origin/<branch>` if you specified a branch.
* If `false`, existing repos are left untouched.

All clones land under `GIT_BASE_DIR` (default `/config/workspace`).

---

## Volumes & persistence

```yaml
volumes:
  code-config:   # persists VS Code user data and script state under /config
  projects:      # persists your workspace repos under /config/workspace
```

You can back these up independently. User assets live in `/config/data/User`; script state in `/config/.gitstrap`.

---

## Troubleshooting

* **Task didn’t appear / keybinding missing** — Ensure `jq` is available in the image (LinuxServer’s image includes it). The script guards against malformed user JSON by backing up and re‑creating minimal valid files.
* **Autorun didn’t trigger** — Set **both** `GH_USERNAME` **and** `GH_PAT` before starting the container. A lock file at `/run/gitstrap/init-gitstrap.lock` prevents duplicate autoruns in the same boot.
* **Git cannot access GitHub** — The script generates an ed25519 key, adds `github.com` to `known_hosts`, and uploads your public key using the PAT. Verify your PAT scopes include `user:email` and `admin:public_key`.
* **Password change banner appeared but login didn’t change** — The hash is written to `FILE__HASHED_PASSWORD`. If code‑server didn’t pick it up, perform a container restart (the restart gate attempts this automatically).
* **Settings keep reverting** — Add the specific keys you want to keep to `gitstrap_preserve` on the corresponding object.

---

## FAQ

**Can I skip all envs and do everything interactively?**
Yes. Leave `GH_USERNAME`/`GH_PAT` or any other env vars empty and just press `ctrl+alt+g` inside code‑server to run the Task.

**Do I need to expose 8443 on the host?**
Only if you’re not fronting this with a reverse proxy. Otherwise, keep the short `:8443` mapping and let your proxy/router handle inbound ports and TLS.

**Where are the managed markers stored?**
Objects written by the script include `"__gitstrap_settings": true`. For settings merges, the script also stores the set of repo‑provided keys in `/config/.gitstrap/managed-settings-keys.json` to enable clean updates.

**What if I want to run only the settings merge or only the gate?**
The script exposes subcommands: `settings-merge`, `gate-install`, `default-pass`, and `codepass set <new> <confirm>`, in addition to the default `init` and the Task’s `force` path.

---