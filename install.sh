#!/usr/bin/env bash
# =============================================================================
# install.sh — extract transfer archive and install Python packages offline
# =============================================================================
# Runs on the HIGHSIDE (air-gapped) machine. No network access required.
#
# Usage:
#   ./install.sh <archive.tgz> <requirements.txt>
#
# Example:
#   ./install.sh packages-20260423-120000.tgz requirements.txt
#
# The packages/ directory is extracted next to this script. pip resolves
# packages entirely from the local directory — no index server is contacted.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ARCHIVE="${1:-}"
REQUIREMENTS="${2:-}"

if [[ -z "$ARCHIVE" || -z "$REQUIREMENTS" ]]; then
  echo "Usage: $0 <archive.tgz> <requirements.txt>" >&2
  exit 1
fi

[[ -f "$ARCHIVE" ]]      || { echo "ERROR: archive not found: ${ARCHIVE}" >&2; exit 1; }
[[ -f "$REQUIREMENTS" ]] || { echo "ERROR: requirements file not found: ${REQUIREMENTS}" >&2; exit 1; }

command -v pip >/dev/null 2>&1 || { echo "ERROR: pip not found on PATH" >&2; exit 1; }

echo "=== install.sh ==="
echo "Archive      : ${ARCHIVE}"
echo "Requirements : ${REQUIREMENTS}"
echo ""

# Verify checksum if sidecar exists
CHECKSUM_FILE="${ARCHIVE}.sha256"
if [[ -f "$CHECKSUM_FILE" ]]; then
  echo "Verifying SHA-256 ..."
  sha256sum --check "$CHECKSUM_FILE"
  echo ""
else
  echo "WARNING: no .sha256 sidecar found — skipping integrity check" >&2
fi

echo "Extracting ${ARCHIVE} ..."
tar -xf "$ARCHIVE" -C "$SCRIPT_DIR"

PACKAGES_DIR="${SCRIPT_DIR}/packages"
[[ -d "$PACKAGES_DIR" ]] || {
  echo "ERROR: expected packages/ directory not found after extraction" >&2
  exit 1
}

PKG_COUNT=$(find "$PACKAGES_DIR" -maxdepth 1 -type f \( -name "*.whl" -o -name "*.tar.gz" -o -name "*.zip" \) | wc -l)
echo "Packages available: ${PKG_COUNT}"
echo ""

echo "Installing from local packages ..."
pip install \
  --no-index \
  --find-links "$PACKAGES_DIR" \
  --requirement "$REQUIREMENTS"

echo ""
echo "=== Done ==="
