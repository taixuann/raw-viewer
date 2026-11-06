#!/usr/bin/env bash
# RawView Universal CLI Installer
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/taixuann/raw-viewer/master/install.sh | bash
#
# Custom options:
#   RAW_VIEWER_VERSION=v0.2.0 curl -fsSL ... | bash
#   RAW_VIEWER_BIN_DIR=/usr/local/bin curl -fsSL ... | bash

set -euo pipefail

REPO="taixuann/raw-viewer"
BIN_NAME="raw-viewer"
DEFAULT_BIN_DIR="$HOME/.local/bin"
BIN_DIR="${RAW_VIEWER_BIN_DIR:-$DEFAULT_BIN_DIR}"
VERSION="${RAW_VIEWER_VERSION:-latest}"

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info() {
  printf "${CYAN}==>${NC} ${BOLD}%b${NC}\n" "$*"
}

success() {
  printf "${GREEN}==>${NC} ${BOLD}%b${NC}\n" "$*"
}

warn() {
  printf "${YELLOW}==> Warning:${NC} %b\n" "$*"
}

error() {
  printf "${RED}==> Error:${NC} %b\n" "$*" >&2
  exit 1
}

# 1. Detect OS and Architecture
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Darwin)
    TARGET_OS="apple-darwin"
    ;;
  Linux)
    TARGET_OS="unknown-linux-gnu"
    ;;
  *)
    error "Unsupported operating system: $OS. For Windows, use install.ps1."
    ;;
esac

case "$ARCH" in
  x86_64|amd64)
    TARGET_ARCH="x86_64"
    ;;
  arm64|aarch64)
    TARGET_ARCH="aarch64"
    ;;
  *)
    error "Unsupported architecture: $ARCH."
    ;;
esac

info "Installing ${BOLD}$BIN_NAME${NC} for ${TARGET_ARCH}-${TARGET_OS}..."

# 2. Resolve version tag
if [ "$VERSION" = "latest" ]; then
  info "Querying latest release from GitHub ($REPO)..."
  LATEST_JSON="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null || true)"
  if [ -n "$LATEST_JSON" ]; then
    VERSION="$(echo "$LATEST_JSON" | grep '"tag_name":' | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')"
  fi
  if [ -z "$VERSION" ] || [ "$VERSION" = "latest" ]; then
    # Fallback to current repository tag if unauthenticated API limit reached
    VERSION="v0.2.0"
    warn "Could not resolve latest release via GitHub API. Using fallback $VERSION."
  fi
fi

info "Selected version: ${GREEN}$VERSION${NC}"

# Asset names
# On macOS, universal or arch-specific archive
if [ "$TARGET_OS" = "apple-darwin" ]; then
  ARCHIVE_NAME="raw-viewer-universal-apple-darwin.tar.gz"
  FALLBACK_ARCHIVE="raw-viewer-${TARGET_ARCH}-apple-darwin.tar.gz"
else
  ARCHIVE_NAME="raw-viewer-${TARGET_ARCH}-${TARGET_OS}.tar.gz"
  FALLBACK_ARCHIVE=""
fi

RELEASE_URL="https://github.com/$REPO/releases/download/$VERSION"
DOWNLOAD_URL="$RELEASE_URL/$ARCHIVE_NAME"

# 3. Download archive to temp directory
TMP_DIR="$(mktemp -d -t raw-viewer-install-XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

info "Downloading ${DOWNLOAD_URL}..."
DOWNLOAD_SUCCESS=false
if curl -fsSL "$DOWNLOAD_URL" -o "$TMP_DIR/$ARCHIVE_NAME" 2>/dev/null; then
  DOWNLOAD_SUCCESS=true
elif [ -n "$FALLBACK_ARCHIVE" ]; then
  DOWNLOAD_URL="$RELEASE_URL/$FALLBACK_ARCHIVE"
  ARCHIVE_NAME="$FALLBACK_ARCHIVE"
  info "Attempting fallback asset ${DOWNLOAD_URL}..."
  if curl -fsSL "$DOWNLOAD_URL" -o "$TMP_DIR/$ARCHIVE_NAME" 2>/dev/null; then
    DOWNLOAD_SUCCESS=true
  fi
fi

if [ "$DOWNLOAD_SUCCESS" = "false" ]; then
  warn "Pre-built binary asset not found for $VERSION on GitHub Releases."
  if command -v cargo >/dev/null 2>&1; then
    info "Rust toolchain detected. Building and installing from source via cargo..."
    cargo install --git "https://github.com/$REPO.git" raw-viewer-cli --root "$TMP_DIR"
    mkdir -p "$BIN_DIR"
    mv "$TMP_DIR/bin/$BIN_NAME" "$BIN_DIR/$BIN_NAME"
    chmod +x "$BIN_DIR/$BIN_NAME"
  else
    error "Failed to download $DOWNLOAD_URL and cargo is not available for source compilation."
  fi
else
  # 4. Optional Checksum Verification
  if curl -fsSL "$RELEASE_URL/SHA256SUMS.txt" -o "$TMP_DIR/SHA256SUMS.txt" 2>/dev/null; then
    info "Verifying SHA256 checksum..."
    cd "$TMP_DIR"
    EXPECTED_SUM="$(grep "$ARCHIVE_NAME" SHA256SUMS.txt | awk '{print $1}' || true)"
    if [ -n "$EXPECTED_SUM" ]; then
      if command -v sha256sum >/dev/null 2>&1; then
        ACTUAL_SUM="$(sha256sum "$ARCHIVE_NAME" | awk '{print $1}')"
      elif command -v shasum >/dev/null 2>&1; then
        ACTUAL_SUM="$(shasum -a 256 "$ARCHIVE_NAME" | awk '{print $1}')"
      else
        ACTUAL_SUM=""
      fi
      if [ -n "$ACTUAL_SUM" ]; then
        if [ "$EXPECTED_SUM" != "$ACTUAL_SUM" ]; then
          error "Checksum mismatch! Expected $EXPECTED_SUM, got $ACTUAL_SUM"
        fi
        info "Checksum verified: ${GREEN}OK${NC}"
      fi
    fi
  fi

  # 5. Extract and install binary
  mkdir -p "$BIN_DIR"
  tar -xzf "$TMP_DIR/$ARCHIVE_NAME" -C "$TMP_DIR"

  if [ ! -f "$TMP_DIR/$BIN_NAME" ]; then
    # Check if unpacked into subfolder
    FOUND_BIN="$(find "$TMP_DIR" -type f -name "$BIN_NAME" | head -n1)"
    if [ -n "$FOUND_BIN" ]; then
      mv "$FOUND_BIN" "$TMP_DIR/$BIN_NAME"
    else
      error "Binary $BIN_NAME not found inside archive."
    fi
  fi

  chmod +x "$TMP_DIR/$BIN_NAME"
  mv "$TMP_DIR/$BIN_NAME" "$BIN_DIR/$BIN_NAME"
fi

success "Successfully installed $BIN_NAME to $BIN_DIR/$BIN_NAME"

# 6. PATH check
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    warn "$BIN_DIR is not in your PATH."
    printf "To add it to your current shell session:\n"
    printf "  export PATH=\"\$PATH:%s\"\n\n" "$BIN_DIR"
    printf "To persist it, add the line above to your ~/.bashrc, ~/.zshrc, or profile.\n\n"
    ;;
esac

# 7. Verification run
if [ -x "$BIN_DIR/$BIN_NAME" ]; then
  info "Running self-test ($BIN_NAME --version)..."
  "$BIN_DIR/$BIN_NAME" --version || true
fi

success "RawView CLI is ready to use!"
printf "\nTry running:\n"
printf "  ${BOLD}%s doctor${NC}            # Verify environment and configuration\n" "$BIN_NAME"
printf "  ${BOLD}%s grammar test --help${NC} # Test filename tokens\n" "$BIN_NAME"
printf "  ${BOLD}%s skills install${NC}      # Install AI skills for Claude / Codex\n\n" "$BIN_NAME"
