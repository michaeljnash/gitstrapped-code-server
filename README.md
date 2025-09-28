# README

> **One-command, GitHub-integrated bootstrap for code-server**
>
> Ships a code-server workspace bootstrapped with github that:
>
> * Bootstraps your workspace with GitHub: generates an SSH key if not present, uploads it to GitHub via a PAT if needed, and clones/pulls specified repositories.
> * Provides a simple CLI (`codestrap`) for interactive or env-driven bootstrap.
> * Sets a first-boot code-server password automatically (optional), and lets you change it later with `codestrap passwd`.

This repository wraps the official LinuxServer.io `code-server` image with `codestrap.sh` and a few conventions that make fresh environments productive in seconds.

---

## Contents

- How it works
- Quick start
- CLI usage
- Environment variables
- Ports & reverse proxy note
- Repository cloning syntax
- Volumes & persistence
- Troubleshooting
- FAQ

---

## How it works

1. Restart gate — `codestrap.sh` installs a tiny supervised Node HTTP service at `127.0.0.1:9000` to request a gentle container restart after sensitive changes (like password updates).
2. First-boot password hash — If `DEFAULT_PASSWORD` is set and no hash exists at `FILE__HASHED_PASSWORD`, a secure Argon2 hash is generated and saved. A one-time marker triggers a supervised restart so code-server picks it up.
3. CLI shim — A `codestrap` executable is installed into `/usr/local/bin`. You can run it from the integrated terminal in code-server or by `docker exec`.
4. Bootstrap (two modes)
   - Env-driven autorun (optional): If both `GH_USERNAME` and `GH_PAT` are set at minimum on container start, bootstrap runs automatically (once per boot).
   - Interactive/manual: Run `codestrap` for prompts, or `codestrap --env` to use env vars without prompts.
5. Password updates — Change the code-server password anytime with `codestrap passwd` (interactive, secure prompts). The restart gate reloads code-server cleanly.

---

## Quick start

1. Copy `.env.example` → `.env`, set at least `DEFAULT_PASSWORD` for a first-boot login (optional but recommended).
2. Adjust `docker-compose.yml` (ports/volumes) to your environment.
3. `docker compose up -d`
4. Open code-server in your browser, then:
   - Interactive bootstrap: open a terminal and run `codestrap` (you’ll be prompted).
   - Env-driven: set `GH_USERNAME` and `GH_PAT` in `.env` and it will autorun on first boot; or run `codestrap --env`.

> You can leave all env vars empty and fully bootstrap interactively with `codestrap`.

---

## CLI usage

codestrap — bootstrap GitHub + manage code-server auth

Usage:
  codestrap                               # interactive bootstrap (prompts if TTY)
  codestrap --env                         # bootstrap using environment variables only
  codestrap [flags...]                    # non-interactive bootstrap using provided flags/env
  codestrap passwd                        # interactive password change (secure prompts)
  codestrap -h | --help                   # help
  codestrap -v | --version                # version

Power-user flags (1:1 with env vars; dash or underscore both accepted):
  --gh-username | --gh_username <val>        → GH_USERNAME
  --gh-pat      | --gh_pat      <val>        → GH_PAT (classic; scopes: user:email, admin:public_key)
  --git-name    | --git_name    <val>        → GIT_NAME
  --git-email   | --git_email   <val>        → GIT_EMAIL
  --gh-repos    | --gh_repos    "<specs>"    → GH_REPOS (owner/repo, owner/repo#branch, https://github.com/owner/repo)
  --pull-existing-repos | --pull_existing_repos <true|false> → PULL_EXISTING_REPOS (default: true)
  --git-base-dir       | --git_base_dir <dir>               → GIT_BASE_DIR (default: /config/workspace)
  --env                                                Use environment variables only (no prompts)

Env-only (no flags):
  DEFAULT_PASSWORD          First-boot only; initial password
  GH_KEY_TITLE              Title for uploaded GitHub SSH key (default "codestrapped-code-server SSH Key")

Examples:
  codestrap
  GH_USERNAME=alice GH_PAT=ghp_xxx codestrap --env
  codestrap --gh-username alice --gh-pat ghp_xxx --gh-repos "alice/app#main, org/infra"
  codestrap --pull-existing-repos false
  codestrap passwd

---

## Environment variables

Defaults are sensible; everything is optional except where noted.

| Variable              | Required | Purpose                                                                                                      |
| --------------------- | :------: | ------------------------------------------------------------------------------------------------------------ |
| TZ                    |    ☐     | Container timezone (e.g., `America/Toronto`).                                                                |
| PUID / PGID           |    ☐     | Host user/group IDs that should own files in `/config`.                                                      |
| DEFAULT_PASSWORD      |    ☐     | First-boot only: generate Argon2 hash to `FILE__HASHED_PASSWORD`.                                           |
| GH_USERNAME           |    ☐     | Set with `GH_PAT` to autorun bootstrap at container start. Also used for default identity.                  |
| GH_PAT                |    ☐     | GitHub PAT (classic) with scopes `user:email, admin:public_key`. Used to upload SSH key and resolve email.  |
| GIT_NAME              |    ☐     | Sets global `git config user.name`. Defaults to `GH_USERNAME`.                                              |
| GIT_EMAIL             |    ☐     | Sets global `git config user.email`. Auto-resolved from GitHub if empty.                                    |
| GH_REPOS              |    ☐     | Comma-separated repos to clone (see below).                                                                  |
| PULL_EXISTING_REPOS   |    ☐     | `true`/`false` — if repo exists, pull/reset (default `true`).                                               |
| GIT_BASE_DIR          |    ☐     | Workspace root inside the container (default `/config/workspace`).                                          |
| GH_KEY_TITLE          |    ☐     | Title for the uploaded GitHub SSH key (default `codestrapped-code-server SSH Key`).                          |

---

## Ports & reverse proxy note

In `docker-compose.yml`, the port binding is shown as `":8443"`. That exposes container port `8443` on a host-assigned random port — handy when a reverse proxy handles TLS/ingress.

Not using a proxy? Pin a host port:

ports:
  - "8443:8443"   # host:container

---

## Repository cloning syntax

`GH_REPOS` accepts a comma-separated list; each item can be:

- `owner/repo` → clones default branch via SSH (after key upload)
- `owner/repo#branch` → clones that branch only
- Full URLs: `https://github.com/owner/repo(.git)` or `ssh://git@github.com/owner/repo.git`

Example:

GH_REPOS="owner1/repo1#main, owner2/repo2, https://github.com/owner3/repo3"

When a target already contains a repo:
- If `PULL_EXISTING_REPOS=true`, `codestrap` will fetch and fast-forward pull, or hard reset to `origin/<branch>` when a branch was specified.
- If `false`, existing repos are left unchanged.

All clones land under `GIT_BASE_DIR` (default `/config/workspace`).

---

## Volumes & persistence

volumes:
  code-config:   # persists VS Code user data and script state under /config
  projects:      # persists your workspace repos under /config/workspace

State lives in `/config/.codestrap`. SSH keys in `/config/.ssh`.

---

## Troubleshooting

- Autorun didn’t trigger — You must set both `GH_USERNAME` and `GH_PAT` before container start. A lock file at `/run/codestrap/init-codestrap.lock` prevents duplicate autoruns in the same boot.
- Git cannot access GitHub — The script generates an ed25519 key, adds `github.com` to `known_hosts`, and uploads the public key using your PAT. Ensure PAT scopes include `user:email` and `admin:public_key`.
- Password change banner appeared but login didn’t change — The Argon2 hash is written to `FILE__HASHED_PASSWORD`. If code-server didn’t pick it up, the restart gate triggers a supervised restart; if that fails, manually restart the container.
- No TTY for prompts — Use flags or `--env`, e.g.:
    GH_USERNAME=alice GH_PAT=ghp_xxx codestrap --env
  or:
    codestrap --gh-username alice --gh-pat ghp_xxx --gh-repos "alice/app#main"
