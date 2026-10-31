#!/usr/bin/env bash
# Validates that a pull request body documents acceptance-case → test/vector mapping.
set -euo pipefail

readonly HEADING='## Acceptance case → test mapping'

usage() {
  echo "Usage: $0 [pr-body-file]" >&2
  echo "  Or set PR_BODY, or run in GitHub Actions with GITHUB_EVENT_PATH." >&2
  exit 2
}

read_body() {
  if [[ $# -ge 1 && -n "${1:-}" ]]; then
    if [[ -f "$1" ]]; then
      cat "$1"
      return 0
    fi
    printf '%s' "$1"
    return 0
  fi
  if [[ -n "${PR_BODY:-}" ]]; then
    printf '%s' "$PR_BODY"
    return 0
  fi
  if [[ -n "${GITHUB_EVENT_PATH:-}" && -f "$GITHUB_EVENT_PATH" ]]; then
    jq -r '.pull_request.body // empty' "$GITHUB_EVENT_PATH"
    return 0
  fi
  usage
}

body="$(read_body "${1:-}")"
if [[ -z "$body" ]]; then
  echo "error: empty PR body" >&2
  exit 1
fi

if ! printf '%s\n' "$body" | grep -qF "$HEADING"; then
  echo "error: missing required section: $HEADING" >&2
  exit 1
fi

rows="$(
  printf '%s\n' "$body" | awk -v h="$HEADING" '
    $0 == h { insec = 1; next }
    insec && /^## / { insec = 0 }
    insec && /^\|/ {
      line = $0
      gsub(/[[:space:]]/, "", line)
      if (line ~ /^\|[-:]+\|/) {
        past_sep = 1
        next
      }
      if (past_sep) {
        rows++
      }
    }
    END { print rows + 0 }
  '
)"

if [[ "$rows" -lt 1 ]]; then
  echo "error: mapping section must include a markdown table with at least one acceptance-case row" >&2
  exit 1
fi

echo "ok: found $HEADING with $rows mapped row(s)"
