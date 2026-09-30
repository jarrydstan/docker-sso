#!/usr/bin/env bash
### Fail when an authentik bump crosses a feature release with breaking changes ###
#
# Usage: check-authentik-breaking.sh <base-ref>
#   <base-ref>  git ref holding the pre-change docker-compose.yaml (e.g. origin/master)
#
# Patch bumps (2026.8.1 -> 2026.8.3) pass. Feature bumps (2026.8 -> 2026.11) are
# checked against the release notes of every feature release in between; any
# "## Breaking changes" section fails the job unless the MR has the
# "breaking-reviewed" label. Fails closed if release notes can't be fetched.
#
# AUTHENTIK_OLD_TAG / AUTHENTIK_NEW_TAG override the tags read from git, for
# testing the script locally.
set -euo pipefail

BASE_REF="${1:?usage: $0 <base-ref>}"
COMPOSE_FILE="docker-compose.yaml"
IMAGE="ghcr.io/goauthentik/server"
NOTES_URL="https://raw.githubusercontent.com/goauthentik/authentik/main/website/docs/releases"
OVERRIDE_LABEL="breaking-reviewed"

tags_in() {
    grep -oE "${IMAGE}:[^[:space:]\"']+" | sed "s#^${IMAGE}:##" | sort -u
}

single_tag() {
    local label="$1" tags="$2"
    if [ -z "$tags" ]; then
        echo "No ${IMAGE} image found in ${label} ${COMPOSE_FILE}" >&2
        exit 1
    fi
    if [ "$(printf '%s\n' "$tags" | wc -l)" -ne 1 ]; then
        echo "authentik server and worker use different tags in ${label} ${COMPOSE_FILE}:" >&2
        printf '  %s\n' $tags >&2
        exit 1
    fi
    printf '%s' "$tags"
}

# "2026.8.3" -> "2026 8"
feature_of() {
    if ! [[ "$1" =~ ^([0-9]{4})\.([0-9]{1,2})(\.[0-9]+)?$ ]]; then
        echo "Unrecognised authentik tag '$1' (expected YYYY.M or YYYY.M.P)" >&2
        exit 1
    fi
    echo "${BASH_REMATCH[1]} $((10#${BASH_REMATCH[2]}))"
}

old_tag="${AUTHENTIK_OLD_TAG:-$(single_tag "base" "$(git show "${BASE_REF}:${COMPOSE_FILE}" | tags_in)")}"
new_tag="${AUTHENTIK_NEW_TAG:-$(single_tag "new" "$(tags_in < "$COMPOSE_FILE")")}"

if [ "$old_tag" = "$new_tag" ]; then
    echo "authentik unchanged (${new_tag}), nothing to check."
    exit 0
fi

# Assign first: set -e ignores a failing substitution inside a here-string.
old_feature="$(feature_of "$old_tag")"
new_feature="$(feature_of "$new_tag")"
read -r old_y old_m <<< "$old_feature"
read -r new_y new_m <<< "$new_feature"
old_key=$((old_y * 100 + old_m))
new_key=$((new_y * 100 + new_m))

echo "authentik: ${old_tag} -> ${new_tag}"
if [ "$new_key" -lt "$old_key" ]; then
    echo "Downgrade across feature releases is not supported by authentik migrations." >&2
    exit 1
fi
if [ "$new_key" -eq "$old_key" ]; then
    echo "Patch release within ${new_y}.${new_m}, no breaking changes expected."
    exit 0
fi

breaking=0
found_target=0
for ((y = old_y; y <= new_y; y++)); do
    for ((m = 1; m <= 12; m++)); do
        key=$((y * 100 + m))
        if [ "$key" -le "$old_key" ] || [ "$key" -gt "$new_key" ]; then
            continue
        fi
        url="${NOTES_URL}/${y}/v${y}.${m}.mdx"
        notes_file="$(mktemp)"
        status="$(curl -sS -o "$notes_file" -w '%{http_code}' "$url")" || status="000"
        case "$status" in
            200) ;;
            404)
                rm -f "$notes_file"
                continue
                ;;
            *)
                echo "Could not fetch release notes ${url} (HTTP ${status}), failing closed." >&2
                exit 1
                ;;
        esac
        [ "$key" -eq "$new_key" ] && found_target=1

        section="$(awk '/^## /{p=0} /^## Breaking changes/{p=1; next} p' "$notes_file")"
        rm -f "$notes_file"
        if [ -n "$(printf '%s' "$section" | tr -d '[:space:]')" ]; then
            breaking=1
            echo
            echo "================ Breaking changes in authentik ${y}.${m} ================"
            printf '%s\n' "$section"
            echo "Full notes: https://docs.goauthentik.io/releases/${y}.${m}"
        else
            echo "authentik ${y}.${m}: no breaking changes listed."
        fi
    done
done

if [ "$found_target" -ne 1 ]; then
    echo "No release notes found for target release ${new_y}.${new_m}, failing closed." >&2
    exit 1
fi

if [ "$breaking" -eq 1 ]; then
    if [[ ",${CI_MERGE_REQUEST_LABELS:-}," == *",${OVERRIDE_LABEL},"* ]]; then
        echo
        echo "Breaking changes present, but MR is labelled '${OVERRIDE_LABEL}'. Allowing."
        exit 0
    fi
    echo
    echo "Breaking changes found. Review them, then add the '${OVERRIDE_LABEL}' label" >&2
    echo "to the MR and run a new pipeline (MR > Pipelines > Run pipeline; retrying" >&2
    echo "this job keeps the old labels) to allow the merge." >&2
    exit 1
fi

echo "No breaking changes between ${old_tag} and ${new_tag}."
