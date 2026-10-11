#!/usr/bin/env bash
# Checks the registry artifacts a pull request changes, with no publish
# credential: each changed manifest.yaml and its README go through
# `lace registry validate`, the validator the registry's publish runs, so the
# check refuses exactly what a publish refuses for the manifest's content. A
# manifest must also bump `version` when it already exists on the base branch,
# and a module must validate in Lace form. What depends on who publishes or on
# what the registry already holds is decided only by the publish; README.md
# lists it.
#
# A module that calls modules from lace.cloud/ resolves them when it
# validates, which needs a registry credential. The block never holds the
# publish token: it takes an optional read-only service token (no publish
# scope) and the visibility the module publishes with. Without a token such a
# module is skipped and its publish validates it; with one, `public`
# validates as the public registry's view and `org_private` as the
# registry view the token's own organization binding gives it.
#
# Inputs, from the action's env (action.yml maps them):
#   LACE_TOKEN     optional read-only service token; read by the lace CLI
#   LACE_AUTH_URL  the Lace API the token belongs to; read by the lace CLI
#   VISIBILITY     public | org_private (the registry's visibility): the view a lace.cloud/ module is
#                  validated against
#   EVENT_NAME, BASE (the pull request's base commit), GITHUB_SHA
#
# Every changed manifest is checked: a failure is recorded, the loop goes
# on, and the step fails at the end naming each failed manifest.

set -euo pipefail

VISIBILITY="${VISIBILITY:-public}"
case "$VISIBILITY" in
  public | org_private) ;;
  *)
    echo "::error::registry-check: visibility must be 'public' or 'org_private', not '${VISIBILITY}'." >&2
    exit 1
    ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib/manifests.sh
source "${HERE}/lib/manifests.sh"
# shellcheck source=SCRIPTDIR/../lib/install-lace.sh
source "${HERE}/lib/install-lace.sh"

fail() {
  echo "::error::registry-check: $*" >&2
  exit 1
}

if [ "${EVENT_NAME:-}" != pull_request ]; then
  fail "this action runs on pull_request, not ${EVENT_NAME:-an unknown event}; publishing is lace-cloud/registry-publish."
fi
[ -n "${BASE:-}" ] || fail "the pull_request event names no base commit."
command -v jq >/dev/null 2>&1 \
  || fail "jq is required to read the module verdict — in a container job, install jq (and curl) before this step"

# A base this clone cannot reach is an error, never "nothing changed".
manifest_ensure_commit "$BASE" "the pull request's base commit" || exit 1

LIST="$(mktemp)"
BASE_MANIFEST="$(mktemp)"
trap 'rm -f "$LIST" "$BASE_MANIFEST"' EXIT INT TERM
manifest_paths_changed "$BASE" "$GITHUB_SHA" | manifest_dirs_of_paths > "$LIST"

manifest_summary_start "Lace registry check"

if [ ! -s "$LIST" ]; then
  echo "registry-check: the pull request changes no manifest directory; nothing to check."
  exit 0
fi

install_lace

FAILED=""

# check_one <dir> — records whether the directory passes and lets the loop
# go on to the next one.
check_one() {
  local d="$1" manifest axis readme base_version head_version verdict rc problems=0 result="ok"
  manifest="${d}/manifest.yaml"
  axis="$(manifest_top_level axis < "$manifest")"
  readme="$(manifest_readme "$d")"

  # The refusal's message is the CLI's own and sits in the log above the
  # annotation. The invocation stands on its own line so its argv is checked
  # against the command tree.
  set +e
  lace registry validate --axis "$axis" --manifest "$manifest" --readme "$readme"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "::error file=${manifest}::${manifest} was refused by the registry validator (exit ${rc}); the CLI's message is in the log above." >&2
    problems=1
    result="failed: registry validate exited ${rc}"
  fi

  if git cat-file -e "${BASE}:${manifest}" 2>/dev/null; then
    git show "${BASE}:${manifest}" > "$BASE_MANIFEST"
    base_version="$(manifest_top_level version < "$BASE_MANIFEST")"
    head_version="$(manifest_top_level version < "$manifest")"
    if [ "$base_version" = "$head_version" ]; then
      echo "::error file=${manifest}::${d} changed but ${manifest} still declares version ${head_version}, which the base branch already has. Bump it." >&2
      problems=1
      result="failed: version not bumped"
    fi
  fi

  if [ "$axis" = module ]; then
    calls_registry=0
    if grep -rqs --include='*.tf' 'source[[:space:]]*=[[:space:]]*"lace.cloud/' "$d"; then
      calls_registry=1
    fi
    if [ "$calls_registry" -eq 1 ] && [ -z "${LACE_TOKEN:-}" ]; then
      echo "::notice file=${manifest}::${d} calls modules from lace.cloud/, which validating needs a registry credential to resolve. The check skips it; pass a read-only token to validate it here, or its publish validates it."
      [ "$problems" -eq 1 ] || result="ok (module validation skipped: calls lace.cloud/)"
    else
      set +e
      if [ "$calls_registry" -eq 1 ] && [ "$VISIBILITY" = public ]; then
        lace module validate --view public --path "$d"
      else
        lace module validate --path "$d"
      fi
      rc=$?
      set -e
      if [ "$rc" -ne 0 ]; then
        problems=1
        result="failed: module validate exited ${rc}"
      else
        verdict="$(jq -r .verdict "${d}/.lace/verdict.json")"
        if [ "$verdict" != already-lace-style ]; then
          echo "::error file=${manifest}::${d} validates as '${verdict}', not already-lace-style. Run lace module convert, then lace module validate." >&2
          problems=1
          result="failed: verdict ${verdict}"
        fi
      fi
    fi
  fi

  if [ "$problems" -eq 1 ]; then
    FAILED="${FAILED}${manifest}"$'\n'
  fi
  manifest_summary_row "$manifest" "$axis" "$result"
}

manifest_for_each "$LIST" check_one

if [ -n "$FAILED" ]; then
  fail "these manifests failed the check: $(printf '%s' "$FAILED" | tr '\n' ' ')"
fi
