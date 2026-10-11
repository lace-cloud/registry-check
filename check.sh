#!/usr/bin/env bash
# Checks the registry artifacts a pull request changes, with no publish
# credential. Each changed manifest directory must pass three checks:
#
#   - its manifest.yaml and README go through `lace registry validate`, the
#     validator the registry's publish runs, so the check refuses exactly what
#     a publish refuses for the manifest's content;
#   - it must carry a version the registry does not hold: `lace registry get`
#     asks the registry which versions of the manifest's identity it holds,
#     and a held one is refused, whatever the base branch declares;
#   - a module must validate in Lace form with `lace module validate`,
#     resolving its lace.cloud/ children as its publication's audience does.
#
# The audience is the visibility the manifests publish with. `public` needs
# no credential: the public registry answers anyone, so both registry reads
# carry none (`--view public`) and a public module's org-private child is
# refused here, by name. `org_private` reads the organization's private rows,
# so it needs the organization's read-only service token, and the check fails
# up front without one. The block never holds the publish token.
#
# Inputs, from the action's env (action.yml maps them):
#   LACE_TOKEN     read-only service token, required for org_private; read by the lace CLI
#   LACE_AUTH_URL  the Lace API whose registry and validator are asked; read by the lace CLI
#   VISIBILITY     public | org_private (the registry's visibility the manifests publish with)
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

VISIBILITY="${VISIBILITY:-public}"
case "$VISIBILITY" in
  public) ;;
  org_private)
    [ -n "${LACE_TOKEN:-}" ] \
      || fail "visibility org_private needs the token input: a read-only service token of the publishing organization (registry:read, no publish scope), so the check can read the organization's private registry. with: token: \${{ secrets.LACE_READ_TOKEN }}"
    ;;
  *) fail "visibility must be 'public' or 'org_private', not '${VISIBILITY}'." ;;
esac

if [ "${EVENT_NAME:-}" != pull_request ]; then
  fail "this action runs on pull_request, not ${EVENT_NAME:-an unknown event}; publishing is lace-cloud/registry-publish."
fi
[ -n "${BASE:-}" ] || fail "the pull_request event names no base commit."
command -v jq >/dev/null 2>&1 \
  || fail "jq is required to read the registry's answers — in a container job, install jq (and curl) before this step"

# A base this clone cannot reach is an error, never "nothing changed".
manifest_ensure_commit "$BASE" "the pull request's base commit" || exit 1

LIST="$(mktemp)"
trap 'rm -f "$LIST"' EXIT INT TERM
manifest_paths_changed "$BASE" "$GITHUB_SHA" | manifest_dirs_of_paths > "$LIST"

manifest_summary_start "Lace registry check"

if [ ! -s "$LIST" ]; then
  echo "registry-check: the pull request changes no manifest directory; nothing to check."
  exit 0
fi

install_lace

FAILED=""

# version_unheld <manifest> <axis> — prints nothing and succeeds when the
# registry holds no version of the manifest's identity at its version;
# otherwise prints the summary result and annotates the manifest. The
# registry is asked as the audience reads it: the public registry with no
# credential, or the organization the manifest's author names (a manifest
# publishes only under its own organization's slug) with the token.
version_unheld() {
  local manifest="$1" axis="$2" author name version answer rc held
  author="$(manifest_top_level author < "$manifest")"
  name="$(manifest_top_level name < "$manifest")"
  version="$(manifest_top_level version < "$manifest")"
  # Each invocation is the whole of its line, so its argv is checked against
  # the command tree.
  set +e
  if [ "$VISIBILITY" = public ]; then
    answer="$(lace registry get --view public -o json "${axis}/${author}/${name}")"
  else
    answer="$(lace registry get --org "$author" -o json "${axis}/${author}/${name}")"
  fi
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "::error file=${manifest}::the registry could not be asked which versions of ${axis}/${author}/${name} it holds: the read exited ${rc}, and the CLI's message is in the log above." >&2
    echo "failed: registry read exited ${rc}"
    return 1
  fi
  if ! held="$(printf '%s' "$answer" | jq -r --arg v "$version" 'any(.versions[]; .version == $v)')"; then
    echo "::error file=${manifest}::the registry's answer for ${axis}/${author}/${name} could not be read." >&2
    echo "failed: unreadable registry answer"
    return 1
  fi
  if [ "$held" = true ]; then
    echo "::error file=${manifest}::$(dirname "$manifest") changed but ${manifest} declares version ${version}, which the registry already holds. A changed directory must carry a version the registry does not hold." >&2
    echo "failed: version ${version} already published"
    return 1
  fi
}

# check_one <dir> — records whether the directory passes and lets the loop
# go on to the next one.
check_one() {
  local d="$1" manifest axis readme verdict rc problems=0 result="ok" refusal
  manifest="${d}/manifest.yaml"
  axis="$(manifest_top_level axis < "$manifest")"
  readme="$(manifest_readme "$d")"

  # The refusal's message is the CLI's own and sits in the log above the
  # annotation.
  set +e
  lace registry validate --axis "$axis" --manifest "$manifest" --readme "$readme"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "::error file=${manifest}::${manifest} was refused by the registry validator (exit ${rc}); the CLI's message is in the log above." >&2
    problems=1
    result="failed: registry validate exited ${rc}"
  # The identity the version is asked under is the one the validator just
  # accepted.
  elif ! refusal="$(version_unheld "$manifest" "$axis")"; then
    problems=1
    result="$refusal"
  fi

  if [ "$axis" = module ]; then
    set +e
    if [ "$VISIBILITY" = public ]; then
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

  if [ "$problems" -eq 1 ]; then
    FAILED="${FAILED}${manifest}"$'\n'
  fi
  manifest_summary_row "$manifest" "$axis" "$result"
}

manifest_for_each "$LIST" check_one

if [ -n "$FAILED" ]; then
  fail "these manifests failed the check: $(printf '%s' "$FAILED" | tr '\n' ' ')"
fi
