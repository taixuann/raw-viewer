#!/usr/bin/env bash
# Validates that every changed file in a PR matches a path declared under ## Owned files.
set -euo pipefail

readonly HEADING='## Owned files'

usage() {
  echo "Usage: $0 <pr-body-file> <changed-files-file>" >&2
  echo "  Or set PR_BODY and CHANGED_FILES (multiline), or CHANGED_FILES_FILE." >&2
  exit 2
}

read_body_file() {
  local arg="${1:-}"
  if [[ -n "${PR_BODY:-}" ]]; then
    printf '%s' "$PR_BODY"
    return 0
  fi
  if [[ -n "$arg" && -f "$arg" ]]; then
    cat "$arg"
    return 0
  fi
  if [[ -n "$arg" ]]; then
    printf '%s' "$arg"
    return 0
  fi
  usage
}

read_changed_file() {
  local arg="${1:-}"
  if [[ -n "${CHANGED_FILES:-}" ]]; then
    printf '%s\n' "$CHANGED_FILES"
    return 0
  fi
  if [[ -n "${CHANGED_FILES_FILE:-}" && -f "$CHANGED_FILES_FILE" ]]; then
    cat "$CHANGED_FILES_FILE"
    return 0
  fi
  if [[ -n "$arg" && -f "$arg" ]]; then
    cat "$arg"
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

normalize_pattern() {
  local line="$1"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  if [[ "$line" == '- '* ]]; then
    line="${line:2}"
  elif [[ "$line" == '* '* ]]; then
    line="${line:2}"
  fi
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  printf '%s' "$line"
}

path_matches_pattern() {
  local path="$1"
  local pattern="$2"
  if [[ -z "$pattern" ]]; then
    return 1
  fi
  if [[ "$pattern" == *'/**' ]]; then
    local prefix="${pattern%/\*\*}"
    [[ "$path" == "$prefix" || "$path" == "$prefix"/* ]]
    return
  fi
  if [[ "$pattern" == *[*?[]* ]]; then
    [[ "$path" == $pattern ]]
    return
  fi
  [[ "$path" == "$pattern" ]]
}

path_is_owned() {
  local path="$1"
  local pattern
  for pattern in "${patterns[@]}"; do
    if path_matches_pattern "$path" "$pattern"; then
      return 0
    fi
  done
  return 1
}

body_file="${1:-}"
changed_file="${2:-}"
if [[ $# -lt 2 && -z "${PR_BODY:-}" && -z "${CHANGED_FILES:-}" && -z "${CHANGED_FILES_FILE:-}" ]]; then
  usage
fi

body="$(read_body_file "$body_file" | strip_cr)"
if [[ -z "$body" ]]; then
  echo "error: empty PR body" >&2
  exit 1
fi

filtered="$(printf '%s\n' "$body" | drop_fenced_blocks)"

mapfile -t raw_patterns < <(
  printf '%s\n' "$filtered" | awk -v heading="$HEADING" '
    $0 == heading { insec = 1; next }
    insec && /^## / { insec = 0 }
    insec {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "" || line ~ /^<!--/ || line ~ /^-->/) next
      print line
    }
  '
)

patterns=()
for line in "${raw_patterns[@]}"; do
  normalized="$(normalize_pattern "$line")"
  if [[ -n "$normalized" && "$normalized" != "(example)" ]]; then
    patterns+=("$normalized")
  fi
done

if [[ "${#patterns[@]}" -lt 1 ]]; then
  echo "error: missing required section: $HEADING (with at least one path or glob)" >&2
  exit 1
fi

mapfile -t changed_paths < <(
  read_changed_file "$changed_file" | strip_cr | awk 'NF { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); if ($0 != "") print $0 }'
)

if [[ "${#changed_paths[@]}" -lt 1 ]]; then
  echo "ok: no changed files to check"
  exit 0
fi

violations=()
for path in "${changed_paths[@]}"; do
  if ! path_is_owned "$path"; then
    violations+=("$path")
  fi
done

if [[ "${#violations[@]}" -gt 0 ]]; then
  echo "error: changed file(s) not covered by $HEADING:" >&2
  for path in "${violations[@]}"; do
    echo "  - $path" >&2
  done
  exit 1
fi

echo "ok: all ${#changed_paths[@]} changed file(s) match declared owned paths"
