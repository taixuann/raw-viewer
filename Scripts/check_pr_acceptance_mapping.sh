#!/usr/bin/env bash
# Validates that a pull request body documents acceptance-case → test/vector mapping.
set -euo pipefail

readonly HEADING_UNICODE='## Acceptance case → test mapping'
readonly HEADING_ASCII='## Acceptance case -> test mapping'

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

strip_cr() {
  tr -d '\r'
}

drop_fenced_blocks() {
  awk '
    /^```/ { infence = !infence; next }
    !infence { print }
  '
}

body="$(read_body "${1:-}" | strip_cr)"
if [[ -z "$body" ]]; then
  echo "error: empty PR body" >&2
  exit 1
fi

filtered="$(printf '%s\n' "$body" | drop_fenced_blocks)"

if ! printf '%s\n' "$filtered" | grep -qE '^## Acceptance case (→|->) test mapping$'; then
  echo "error: missing required section: $HEADING_UNICODE (or ASCII arrow variant)" >&2
  exit 1
fi

read -r rows example_rows <<<"$(
  printf '%s\n' "$filtered" | awk '
    /^## Acceptance case (→|->) test mapping$/ { insec = 1; next }
    insec && /^## / { insec = 0 }
    insec && /^\|/ {
      line = $0
      gsub(/[[:space:]]/, "", line)
      if (line ~ /^\|[-:]+\|/) {
        past_sep = 1
        next
      }
      if (past_sep) {
        if ($0 ~ /\(example\)/) {
          example_rows++
        } else {
          rows++
        }
      }
    }
    END {
      printf "%s %s", rows + 0, example_rows + 0
    }
  '
)"

if [[ "$example_rows" -gt 0 ]]; then
  echo "error: mapping table must not contain placeholder rows with (example)" >&2
  exit 1
fi

if [[ "$rows" -lt 1 ]]; then
  echo "error: mapping section must include a markdown table with at least one acceptance-case row" >&2
  exit 1
fi

echo "ok: acceptance-case mapping table with $rows mapped row(s)"
