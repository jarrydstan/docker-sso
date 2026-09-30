# AGENTS.md

Guidance for coding agents working in this repo. See `README.md` for the full picture.

## What this repo is

Docker Compose config for a single production VM running Authentik (SSO) and GitLab CE behind a Traefik proxy on another host. There is no application code, no build and no unit test suite: the "code" is `docker-compose.yaml`, shell scripts and CI/Renovate config.

**The checkout on the Docker host is production.** Files there are live config for running containers, and CI deploys into it.

## Safety rules

- Ask before any change to the running system: `docker compose up/down/restart/pull`, recreating containers, editing files in the host checkout, git commits/pushes, SSH keys, or system settings. Read-only inspection (`docker ps/stats/logs/inspect`, `free`, `/proc`, `git log/diff`) is fine.
- Never commit `.env`, `certs/`, `cloudflare/`, `letsencrypt/`, `gitlab/`, `custom-templates/` or `current_email/`. They're gitignored and hold secrets or host state.
- Never read or print secrets from `.env` or `gitlab/config/gitlab-secrets.json`. Reading a single non-secret key (e.g. `grep '^ROOT_DOMAIN' .env`) is fine.
- Don't switch branches in the host checkout. `deploy.sh` requires `master`. Use `git worktree add <scratch-dir> <branch>` to work on another branch.
- Don't start or restart GitLab casually. It takes 3–5 minutes to boot and is this repo's own git remote and CI server.

## Constraints to keep

- **GitLab stays out of CI and auto-deploy.** It's in the `prod` profile in `docker-compose.ci.yaml` and in `MANUAL_SERVICES` in `deploy.sh`, and Renovate never automerges `gitlab/gitlab-ce`. Keep all three in place.
- **Authentik server and worker use the same pinned tag** (`YYYY.M.P`). `ci/check-authentik-breaking.sh` fails if they differ or if the tag isn't calendar-versioned.
- **Healthchecks for Authentik use `ak healthcheck`.** The image has no `curl`.
- **Keep the Authentik server's `start_period: 5m`.** First boot (every CI run) and feature upgrades run DB migrations for over a minute before the server answers. The worker waits for `server: service_healthy`, so a short start period fails `test-compose` and deploys.
- **GitLab healthcheck** uses `curl --cacert /etc/gitlab/ssl/gitlab-selfsigned.crt https://localhost/-/health`. GitLab nginx serves HTTPS only; port 80 just redirects.
- **Keep GitLab's `mem_limit` and `memswap_limit` equal.** Docker refuses to create the container if `memswap_limit < mem_limit`.
- Pin image tags. Renovate proposes the updates.
- `nginx['real_ip_trusted_addresses']` must list only the Traefik host(s). The old IPv6 entry is stale (the ISP prefix changed); don't add more like it.

## Validating changes

No local yamllint or shellcheck is installed on the host. Useful checks:

```bash
# Compose renders (needs a .env; in a worktree, copy example.env to .env first)
docker compose config -q
COMPOSE_FILE=docker-compose.yaml:docker-compose.ci.yaml docker compose --env-file example.env config --services

# Script syntax
bash -n ci.sh deploy.sh ci/check-authentik-breaking.sh

# Breaking-change gate with tag overrides (exit 0 = pass, 1 = blocked)
AUTHENTIK_OLD_TAG=2026.8.3 AUTHENTIK_NEW_TAG=2026.11.1 bash ci/check-authentik-breaking.sh HEAD

# deploy.sh input validation (safe: exits before touching anything)
./deploy.sh not-a-sha   # expect exit 1

# YAML parse using GitLab's embedded Ruby (if the gitlab container is running)
docker exec -i gitlab /opt/gitlab/embedded/bin/ruby -ryaml -e 'YAML.safe_load($stdin.read); puts :ok' < .gitlab-ci.yml
```

Never run `deploy.sh` with a real SHA outside CI. It fast-forwards the host checkout and recreates containers.

## Conventions

- Conventional Commits (`feat(ci): …`, `fix(authentik): …`, `chore(deps): …`).
- Shell scripts: bash with `set -euo pipefail`, and `printf` rather than `echo -e` (`/bin/sh` on the host is dash). CI scripts that run in Alpine images may use `#!/bin/sh`.
- Match the existing style of `docker-compose.yaml`: env vars as `${VAR}` from `.env`, static IPs on the named networks, a healthcheck on every long-running service.

## Gotchas

- **Docker-in-Docker bind mounts:** `test-compose` bind-mounts repo paths into containers inside dind. That only works if the runner shares `/builds` with the dind service.
- **Break-glass GitLab access** is `https://192.168.1.141` (self-signed). Never the hostname: `git.jarryd.cc` has HSTS cached in browsers, which blocks click-through.
- **Hairpin NAT:** clients that resolve `git.jarryd.cc` via public DNS reach Traefik through the router, so GitLab logs them as `192.168.1.1`. Local clients should resolve it to `192.168.1.60`.
- **Memory ballooning:** the VM is a Proxmox guest. If it slows down under GitLab, check `/proc/vmstat` balloon counters before tuning GitLab.
- **`socket-proxy` publishes port 2375 on all host interfaces** with `POST=1` and `CONTAINERS=1`, i.e. write access to the Docker API from the LAN. Treat it as sensitive; don't widen its permissions.
