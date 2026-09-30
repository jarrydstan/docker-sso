# docker-sso

Self-hosted **Authentik** identity provider plus a **GitLab CE** instance, deployed with Docker Compose on a single VM behind a Traefik reverse proxy.

## Services

| Service | Image | Purpose |
| --- | --- | --- |
| `server` (`authentik-sv`) | `ghcr.io/goauthentik/server` | Authentik web/API, SSO (OIDC/SAML). Ports `9000` (HTTP), `9443` (HTTPS) |
| `worker` (`authentik-work`) | `ghcr.io/goauthentik/server` | Authentik background tasks; manages outposts through the socket proxy |
| `postgresql` (`authentik-pg`) | `postgres:16-alpine` | Authentik database |
| `socket-proxy` | `tecnativa/docker-socket-proxy` | Filtered Docker API for the Authentik worker/outposts. Port `2375` |
| `gitlab` | `gitlab/gitlab-ce` | Git hosting and CI. Ports `80` (redirects to HTTPS), `443`, `2424` (Git over SSH) |
| `certbot` | `certbot/dns-cloudflare` | Renews the wildcard certificate via Cloudflare DNS-01, then exits |
| `deunhealth` | `qmcgaw/deunhealth` | Restarts containers labelled to be restarted when unhealthy |
| `beszel-agent` | `henrygd/beszel-agent` | Host/container metrics for Beszel (host network, port `45876`) |

The LDAP outpost container (`ak-outpost-ldap`) is created and managed by Authentik itself, not by this compose file.

## Setup

1. Clone the repo onto the Docker host.
2. Create the environment file and fill in real values:

   ```bash
   cp example.env .env
   ```

   Key variables: database credentials (`PG_*`), `AUTHENTIK_SECRET_KEY`, SMTP settings (`AUTHENTIK_EMAIL__*`), `ROOT_DOMAIN`, `GITLAB_URL`, `BESZEL_KEY`, and the network subnets/static IPs (`*_IPV4`, `*_IPV6`, `*_IP`).
3. Add the Cloudflare API credentials for certbot at `./cloudflare/credentials` (`chmod 600`).
4. Start the stack:

   ```bash
   docker compose up -d
   ```

## Directory layout

| Path | Contents | In git |
| --- | --- | --- |
| `docker-compose.yaml` | All services | yes |
| `docker-compose.ci.yaml` | CI override (skips `certbot` and `gitlab`, moves the socket-proxy port) | yes |
| `data/` | Authentik media (icons, branding, flow backgrounds) | yes |
| `css/`, `images/`, `email/` | Authentik branding, CSS and email templates | yes |
| `ci/`, `ci.sh`, `deploy.sh` | CI/CD scripts | yes |
| `.env` | Secrets and host-specific settings | **no** |
| `certs/`, `letsencrypt/`, `cloudflare/` | Certificates, certbot logs, Cloudflare credentials | **no** |
| `gitlab/` | GitLab config (incl. `gitlab-secrets.json`), logs and data | **no** |
| `custom-templates/`, `current_email/` | Host-local Authentik templates | **no** |

## GitLab

GitLab is **updated manually**. It is excluded from CI and from `deploy.sh` because upgrading it restarts the server that runs the pipeline, and GitLab upgrades need their own care (upgrade paths, background migrations).

To upgrade after merging a Renovate MR:

```bash
docker compose pull gitlab && docker compose up -d gitlab
```

Boot takes about 3–5 minutes; the healthcheck allows a 5 minute start period.

### Resources

- Memory is capped at 8 GB (`mem_limit`/`memswap_limit`) so GitLab can't swap-thrash the whole VM.
- Puma runs a single worker and the Prometheus exporters are disabled to keep memory use down.
- The VM needs real RAM for GitLab. If it is a Proxmox guest, make sure memory ballooning isn't shrinking it (`grep MemTotal /proc/meminfo` should match the configured size).

### HTTPS and break-glass access

`external_url` is `https://git.jarryd.cc`. Traefik terminates the public certificate and proxies to GitLab's own nginx over HTTPS.

GitLab serves HTTPS itself with a **self-signed certificate** (`gitlab/config/ssl/gitlab-selfsigned.{crt,key}`, valid until 2036). The certificate is valid for `git.jarryd.cc`, `localhost`, `192.168.1.141` and `127.0.0.1`.

**If Traefik is down**, open **`https://192.168.1.141`** and click through the certificate warning.

- Use the IP with `https://`. `http://` redirects to `https://git.jarryd.cc`, which goes through Traefik.
- Don't use the hostname. Browsers have HSTS stored for `git.jarryd.cc` and won't let you click through a self-signed certificate on it. HSTS never applies to IP addresses.
- If you normally log in through Authentik SSO, use a local GitLab account; Authentik is behind Traefik too.

`nginx['real_ip_trusted_addresses']` trusts Traefik (`192.168.1.60`), so GitLab logs show real client IPs. Direct clients can't spoof `X-Forwarded-For`.

## CI/CD

Pipelines run for merge requests and for pushes to `master` (see `.gitlab-ci.yml`).

| Job | Runs on | What it does |
| --- | --- | --- |
| `yamllint` | MR, master | Lints all YAML (`relaxed` rules) |
| `authentik-breaking-changes` | MRs changing `docker-compose.yaml` | Blocks Authentik upgrades whose release notes list breaking changes |
| `test-compose` | MR, master | Boots the stack in Docker-in-Docker with `ci.sh` (no GitLab, no certbot) and tears it down |
| `deploy-compose` | master only, after merge | SSHes to the host and runs `deploy.sh <sha>` |

### Authentik breaking-change gate

`ci/check-authentik-breaking.sh` compares the Authentik tag on the MR with the target branch:

- Patch bumps (`2026.8.1` → `2026.8.3`) pass.
- Feature bumps (`2026.8` → `2026.11`) fetch the release notes of every feature release in between. Any `## Breaking changes` section fails the job and prints it.
- Missing release notes, invalid tags, downgrades, or server/worker on different tags fail the job.

To merge after reviewing the breaking changes: add the MR label **`breaking-reviewed`**, then start a **new** pipeline from the MR (Pipelines → Run pipeline). Retrying the failed job reuses the old labels and fails again.

Test locally with tag overrides:

```bash
AUTHENTIK_OLD_TAG=2026.8.3 AUTHENTIK_NEW_TAG=2026.11.1 bash ci/check-authentik-breaking.sh HEAD
```

### Deploy

`deploy.sh` runs on the host via a forced SSH command:

1. Refuses to run unless the host checkout is on `master`.
2. Fetches from the `deploy` remote and fast-forwards to exactly the commit that passed CI. Local commits or conflicting local edits stop the deploy instead of being overwritten.
3. Pulls and starts every service **except `gitlab` and `certbot`**, waiting up to 10 minutes for healthchecks.

Deploys are serialised through the `production` resource group.

### Required setup

**GitLab project settings**

- Settings → Merge requests → **Pipelines must succeed** (otherwise Renovate automerge ignores CI).
- Protect `master`.
- CI/CD variables (protected):
  - `SSH_PRIVATE_KEY` (File): private key the runner uses to log in to the host.
  - `SSH_KNOWN_HOSTS` (File): output of `ssh-keyscan -t ed25519 <host>`.
  - `DOCKER_REMOTE_HOST`: e.g. `jarryd@192.168.1.141`.

**Host: runner login key**, in `~/.ssh/authorized_keys`, restricted to the deploy script:

```text
command="/home/jarryd/docker-sso/deploy.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA... gitlab-runner01_docker-sso
```

**Host: read-only fetch key.** Add its public key under Project → Settings → Repository → **Deploy keys** with write access unchecked, then:

```text
# ~/.ssh/config
Host gitlab-deploy
  HostName 127.0.0.1
  Port 2424
  User git
  IdentityFile ~/.ssh/docker-sso-deploy
  IdentitiesOnly yes
```

```bash
git remote add deploy gitlab-deploy:jarrydstanbrook/docker-sso.git
ssh -T gitlab-deploy   # should greet "Anonymous", not your username
```

This connects straight to GitLab's SSH port, so deploys still work when Traefik is down.

## Renovate

`renovate.json`:

- Minor, patch, digest and pin updates **automerge once CI passes**, only between 00:00 and 05:59 Australia/Melbourne.
- Major updates wait for manual review.
- Authentik feature releases are held by the breaking-change gate above.
- `gitlab/gitlab-ce` **never automerges**. Its MRs get the `manual-deploy` label; update GitLab by hand after merging.
- The CI `docker` and `docker:dind` images are updated together.

## Troubleshooting

- **VM grinds to a halt when GitLab starts:** check for memory ballooning (`grep -E 'balloon_(inflate|deflate)' /proc/vmstat`, `free -h`). Non-zero inflate with a small `MemTotal` means the hypervisor has reclaimed the RAM.
- **Authentik container shows `unhealthy` but works:** the Authentik image doesn't ship `curl`. Healthchecks must use `ak healthcheck`.
- **`test-compose` fails with `dependency failed to start: container authentik-sv is unhealthy`:** the server was still running first-boot migrations when its healthcheck gave up. Keep `start_period: 5m` on the server healthcheck.
- **`test-compose` fails with "not a directory":** the runner isn't sharing `/builds` with the dind service, so bind mounts resolve to empty paths inside dind.
- **Deploy fails with exit 3:** the host checkout isn't on `master`, or it has local changes that block a fast-forward.
