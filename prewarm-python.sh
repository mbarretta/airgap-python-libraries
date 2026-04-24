#!/usr/bin/env bash
# =============================================================================
# prewarm-python.sh — Python pip download + PEP 740 attestation fetch
# =============================================================================
# Runs on the LOWSIDE (connected) machine.
#
# What it does:
#   1. Walks ROOT_DIR for requirements*.txt and pyproject.toml files
#   2. Runs `pip download` against each, routed through Chainguard Libraries;
#      all wheels + sdists land in PACKAGES_DIR
#   3. For every downloaded file, fetches the PEP 740 attestation from
#      libraries.cgr.dev and saves it as <file>.provenance alongside the dist
#
# Prerequisites:
#   ~/.netrc must contain credentials for libraries.cgr.dev:
#
#     machine libraries.cgr.dev
#     login    <username>
#     password <password>
#
#   Create a pull token with:
#     chainctl auth pull-token create --repository=python --ttl=8760h
#
#   See: https://edu.chainguard.dev/chainguard/libraries/python/build-configuration/
#
# Usage:
#   ./prewarm-python.sh [projects-root] [packages-dir]
#
# Defaults:
#   projects-root  /projects
#   packages-dir   ./packages
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROOT_DIR="${1:-/projects}"
PACKAGES_DIR="${2:-${SCRIPT_DIR}/packages}"

FAILURES=0
ATTEST_OK=0
ATTEST_MISS=0

CG_PYTHON_INDEX="https://libraries.cgr.dev/python/simple/"
CG_PYTHON_INTEGRITY="https://libraries.cgr.dev/python/integrity"

# ── Pre-flight ────────────────────────────────────────────────────────────────
[[ -d "$ROOT_DIR" ]] || { echo "ERROR: projects root not found: ${ROOT_DIR}" >&2; exit 1; }

python3 - <<'PY'
import netrc, sys
try:
    entry = netrc.netrc().authenticators("libraries.cgr.dev")
except FileNotFoundError:
    entry = None
if not entry:
    print("ERROR: no credentials for libraries.cgr.dev in ~/.netrc", file=sys.stderr)
    print("", file=sys.stderr)
    print("Add them with:", file=sys.stderr)
    print("  chainctl auth pull-token create --repository=python --ttl=8760h", file=sys.stderr)
    print("  # Then append to ~/.netrc:", file=sys.stderr)
    print("  machine libraries.cgr.dev", file=sys.stderr)
    print("  login    <username>", file=sys.stderr)
    print("  password <password>", file=sys.stderr)
    print("  chmod 600 ~/.netrc", file=sys.stderr)
    sys.exit(1)
PY

PIP=$(command -v pip3 2>/dev/null || command -v pip 2>/dev/null || true)
[[ -n "$PIP" ]] || {
  echo "ERROR: pip / pip3 not found on PATH" >&2
  echo "       Install with: sudo apt-get install -y python3-pip" >&2
  exit 1
}

command -v curl >/dev/null || { echo "ERROR: curl not found on PATH" >&2; exit 1; }

mkdir -p "$PACKAGES_DIR"

echo "=== Python pre-warm — ${ROOT_DIR} ==="
echo "Packages dir : ${PACKAGES_DIR}"
echo ""

# ── Phase 1: pip download ─────────────────────────────────────────────────────
echo "Phase 1: downloading Python distributions ..."

while IFS= read -r req; do
  echo "  → ${req}"
  if ! "$PIP" download \
        --quiet \
        --index-url "$CG_PYTHON_INDEX" \
        --prefer-binary \
        --dest "$PACKAGES_DIR" \
        --requirement "$req" 2>/dev/null; then
    echo "    [FAIL] ${req}" >&2
    FAILURES=$(( FAILURES + 1 ))
  fi
done < <(find "$ROOT_DIR" -name "requirements*.txt" \
           -not -path "*/.git/*" \
           -not -path "*/node_modules/*" | sort)

while IFS= read -r proj; do
  dir=$(dirname "$proj")
  echo "  → ${dir}"
  if ! "$PIP" download \
        --quiet \
        --index-url "$CG_PYTHON_INDEX" \
        --prefer-binary \
        --dest "$PACKAGES_DIR" \
        "$dir" 2>/dev/null; then
    echo "    [warn] pyproject download failed for ${dir}"
  fi
done < <(find "$ROOT_DIR" -name "pyproject.toml" \
           -not -path "*/.git/*" \
           -not -path "*/node_modules/*" | sort)

# ── Phase 2: PEP 740 provenance fetch ─────────────────────────────────────────
# URL pattern: libraries.cgr.dev/python/integrity/<pkg>/<version>/<file>/provenance
# Credentials are read from ~/.netrc by curl --netrc.

echo ""
echo "Phase 2: fetching PEP 740 attestations ..."

parse_pkg_version() {
  local fn="$1"
  local base="${fn%.whl}"
  if [[ "$fn" != *.whl ]]; then
    base="${fn%.tar.gz}"
    base="${base%.zip}"
  fi
  IFS='-' read -ra PARTS <<< "$base"
  local i
  for (( i=${#PARTS[@]}-1; i>=0; i-- )); do
    if [[ "${PARTS[$i]}" =~ ^[0-9] ]]; then
      PKG=$(IFS=- ; echo "${PARTS[*]:0:$i}")
      VER="${PARTS[$i]}"
      return 0
    fi
  done
  return 1
}

while IFS= read -r dist; do
  fn=$(basename "$dist")
  [[ "$fn" == *.provenance ]] && continue
  dest="${dist}.provenance"
  [[ -f "$dest" ]] && continue

  if ! parse_pkg_version "$fn"; then
    echo "    [warn] could not parse pkg/version from ${fn}"
    continue
  fi

  url="${CG_PYTHON_INTEGRITY}/${PKG}/${VER}/${fn}/provenance"
  http_code=$(curl --netrc --silent --fail \
    --output "$dest" \
    --write-out "%{http_code}" \
    "$url" 2>/dev/null || echo "000")
  if [[ "$http_code" == "200" ]]; then
    ATTEST_OK=$(( ATTEST_OK + 1 ))
  else
    rm -f "$dest"
    ATTEST_MISS=$(( ATTEST_MISS + 1 ))
  fi
done < <(find "$PACKAGES_DIR" -maxdepth 1 -type f \
           \( -name "*.whl" -o -name "*.tar.gz" -o -name "*.zip" \) | sort)

echo ""
echo "=== Python pre-warm complete ==="
echo "Packages dir      : ${PACKAGES_DIR}"
echo "Build failures    : ${FAILURES}"
echo "Provenance OK     : ${ATTEST_OK}"
echo "Provenance missing: ${ATTEST_MISS} (expected for some upstream packages)"
