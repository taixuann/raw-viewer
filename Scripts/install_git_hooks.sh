#!/usr/bin/env bash
# Install repository git hooks (pre-push)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

HOOK_DIR="$ROOT_DIR/.git/hooks"
if [ ! -d "$HOOK_DIR" ]; then
  echo "Error: .git/hooks directory not found. Not a git repository?" >&2
  exit 1
fi

cat << 'EOF' > "$HOOK_DIR/pre-push"
#!/usr/bin/env bash
# Git pre-push hook: run local sanity checks before pushing to remote CI.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
echo "==> [pre-push] Running local pre-push checks via Scripts/pre_push.sh..."
"$REPO_ROOT/Scripts/pre_push.sh"
EOF

chmod +x "$HOOK_DIR/pre-push"
echo "==> Successfully installed pre-push hook: $HOOK_DIR/pre-push"
