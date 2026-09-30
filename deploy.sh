#!/usr/bin/env bash
### CI/CD Deploy Script for docker-sso ###
#
# Usage: deploy.sh <commit-sha>
#   Called by the deploy-compose CI job over SSH. The host's authorized_keys
#   entry forces this script, so the SHA arrives as SSH_ORIGINAL_COMMAND.
#
# Fast-forwards the host checkout to exactly the commit that passed CI, then
# pulls and starts every service except the ones in MANUAL_SERVICES, which
# must be updated by hand.
set -euo pipefail

MANUAL_SERVICES="gitlab certbot"
DEPLOY_REMOTE="${DEPLOY_REMOTE:-deploy}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-master}"

section_start() { printf '\e[0Ksection_start:%s:%s[collapsed=true]\r\e[0K%s\n' "$(date +%s)" "$1" "$2"; }
section_end() { printf '\e[0Ksection_end:%s:%s\r\e[0K\n' "$(date +%s)" "$1"; }
info() { printf '\e[33m%s\e[0m\n' "$*"; }
ok() { printf '\e[32m%s\e[0m\n' "$*"; }
fail() { printf '\e[31m%s\e[0m\n' "$1" >&2; exit "${2:-1}"; }

# Everything runs inside main so bash has parsed the whole script before
# git replaces this file on disk.
main() {
    local sha="${1:-${SSH_ORIGINAL_COMMAND:-}}"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || fail "Usage: deploy.sh <40-char commit sha>, got '${sha}'"

    cd "$(dirname "$(readlink -f "$0")")"

    local branch
    branch="$(git symbolic-ref --quiet --short HEAD)" || branch="(detached)"
    [ "$branch" = "$DEPLOY_BRANCH" ] ||
        fail "Host checkout is on '${branch}', expected '${DEPLOY_BRANCH}'; switch it back before deploying" 3

    section_start update "Updating checkout"
    info "Fetching ${DEPLOY_REMOTE}/${DEPLOY_BRANCH}..."
    git fetch --quiet "$DEPLOY_REMOTE" "$DEPLOY_BRANCH"
    git merge-base --is-ancestor "$sha" "${DEPLOY_REMOTE}/${DEPLOY_BRANCH}" ||
        fail "Commit ${sha} is not on ${DEPLOY_REMOTE}/${DEPLOY_BRANCH}"
    # --ff-only refuses to clobber local commits or conflicting local edits.
    git merge --ff-only --quiet "$sha" ||
        fail "Host checkout can't fast-forward to ${sha}; resolve local changes on the host" 3
    ok "Checkout at $(git rev-parse --short HEAD)."
    section_end update

    local services=()
    local service
    while read -r service; do
        [[ " ${MANUAL_SERVICES} " == *" ${service} "* ]] || services+=("$service")
    done < <(docker compose config --services)
    info "Deploying: ${services[*]}"
    info "Skipping (manual): ${MANUAL_SERVICES}"

    section_start pull "Pulling images"
    docker compose pull --quiet "${services[@]}" || fail "Docker pull failed." 1
    ok "Docker images pulled successfully."
    section_end pull

    section_start start "Starting containers"
    if ! docker compose up -d --wait --wait-timeout 600 --quiet-pull "${services[@]}"; then
        docker compose logs -n 100 "${services[@]}" || true
        docker compose ps -a || true
        fail "Docker containers failed to start." 2
    fi
    ok "Docker containers started successfully."
    section_end start

    ok "CI/CD deploy for docker-sso completed"
}

main "$@"
