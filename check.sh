#!/usr/bin/env bash
# Checks the registry artifacts a pull request changes, with no credential:
# each changed manifest.yaml's directory must carry the manifest envelope
# keys and a known axis, must declare `runtime` exactly when its axis runs
# code (scanner, handler, agent; never a module), must bump `version` when
# the manifest already exists on the base branch, and — for a module — must
# validate in Lace form. The registry still decides every publish; this
# catches what a reviewer would otherwise find only after merge.
#
# A module that calls modules from lace.cloud/ is not validated here:
# validating it resolves those calls, which needs a registry credential a
# pull request does not hold. Its publish validates it.
#
# Inputs, from the action's env (action.yml maps them):
#   LACE_VERSION   the lace release to check with; empty = the pin
#   EVENT_NAME, BASE (the pull request's base commit), GITHUB_SHA
#
# Every changed manifest is checked: a failure is recorded, the loop goes
# on, and the step fails at the end naming each failed manifest.

set -euo pipefail

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
  local d="$1" manifest key axis base_version head_version verdict rc problems=0 result="ok"
  manifest="${d}/manifest.yaml"

  for key in apiVersion axis author name version displayName; do
    if ! grep -q "^${key}:" "$manifest"; then
      echo "::error file=${manifest}::${manifest} has no top-level '${key}:'." >&2
      problems=1
    fi
  done
  if [ "$problems" -eq 1 ]; then
    FAILED="${FAILED}${manifest}"$'\n'
    manifest_summary_row "$manifest" "?" "failed: missing envelope key"
    return 0
  fi

  axis="$(manifest_top_level axis < "$manifest")"
  case "$axis" in
    module)
      if grep -q '^runtime:' "$manifest"; then
        echo "::error file=${manifest}::${manifest} is a module and declares 'runtime:'; a module has no runtime. Delete the block." >&2
        problems=1
        result="failed: module declares runtime"
      fi
      ;;
    scanner | handler | agent)
      if ! grep -q '^runtime:' "$manifest"; then
        echo "::error file=${manifest}::${manifest} is a ${axis} and has no top-level 'runtime:'." >&2
        problems=1
        result="failed: no runtime"
      fi
      ;;
    *)
      echo "::error file=${manifest}::${manifest} declares axis '${axis}'; it must be one of module, scanner, handler, agent." >&2
      FAILED="${FAILED}${manifest}"$'\n'
      manifest_summary_row "$manifest" "$axis" "failed: unknown axis"
      return 0
      ;;
  esac

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
    if grep -rqs --include='*.tf' 'source[[:space:]]*=[[:space:]]*"lace.cloud/' "$d"; then
      echo "::notice file=${manifest}::${d} calls modules from lace.cloud/, which validating needs a registry credential to resolve. The check skips it; its publish validates it."
      [ "$problems" -eq 1 ] || result="ok (module validation skipped: calls lace.cloud/)"
    else
      set +e
      lace module validate --path "$d"
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
