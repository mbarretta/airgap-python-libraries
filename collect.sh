#!/usr/bin/env bash
# =============================================================================
# collect.sh — download Python packages and package them for diode transfer
# =============================================================================
# Runs on the LOWSIDE (connected) machine.
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
#   Some packages ship only as source distributions and require a build
#   toolchain to generate metadata (e.g. packages using Meson + Fortran).
#   Install on Debian/Ubuntu if needed:
#     sudo apt-get install -y build-essential gfortran pkg-config python3-dev
#
# Usage:
#   ./collect.sh <requirements.txt> [archive-name] [options]
#
# Options:
#   --extra-python-versions X.Y,X.Z
#   -p X.Y,X.Z        Comma-separated additional Python versions to collect
#                     binary wheels for. Uses --only-binary :all: — packages
#                     without a wheel for that version are silently skipped.
#
#   --provenance      Also fetch PEP 740 provenance sidecars (.provenance files)
#                     for every downloaded artifact. Requires curl. Sidecars are
#                     included in the transfer archive. Packages without a
#                     provenance record are skipped with a count at the end.
#
# Output:
#   packages/                        flat directory of wheels, sdists, and
#                                    optional .provenance sidecars
#   <name>-<YYYYMMDD-HHMMSS>.tgz    transfer archive
#   <name>-<YYYYMMDD-HHMMSS>.tgz.sha256
#   <name>-<YYYYMMDD-HHMMSS>.failures.txt   packages that could not be downloaded
#
# On subsequent runs, pip download skips files already in packages/ so only
# new or updated packages are fetched.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REQUIREMENTS=""
ARCHIVE_NAME="packages"
EXTRA_VERSIONS=""
FETCH_PROVENANCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --extra-python-versions|-p)
      EXTRA_VERSIONS="$2"; shift 2 ;;
    --extra-python-versions=*)
      EXTRA_VERSIONS="${1#*=}"; shift ;;
    --provenance)
      FETCH_PROVENANCE=1; shift ;;
    *)
      if [[ -z "$REQUIREMENTS" ]]; then
        REQUIREMENTS="$1"
      else
        ARCHIVE_NAME="$1"
      fi
      shift ;;
  esac
done

if [[ -z "$REQUIREMENTS" ]]; then
  echo "Usage: $0 <requirements.txt> [archive-name] [--extra-python-versions X.Y,X.Z] [--provenance]" >&2
  exit 1
fi

[[ -f "$REQUIREMENTS" ]] || { echo "ERROR: requirements file not found: ${REQUIREMENTS}" >&2; exit 1; }

# Verify ~/.netrc has an entry for libraries.cgr.dev
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

if [[ $FETCH_PROVENANCE -eq 1 ]]; then
  command -v curl >/dev/null || {
    echo "ERROR: curl not found on PATH (required for --provenance)" >&2
    exit 1
  }
fi

PACKAGES_DIR="${SCRIPT_DIR}/packages"
mkdir -p "$PACKAGES_DIR"

TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)
ARCHIVE="${SCRIPT_DIR}/${ARCHIVE_NAME}-${TIMESTAMP}.tgz"
FAILURES_LOG="${SCRIPT_DIR}/${ARCHIVE_NAME}-${TIMESTAMP}.failures.txt"
FAILURES=0

echo "=== collect.sh — ${TIMESTAMP} ==="
echo "Requirements  : ${REQUIREMENTS}"
echo "Packages dir  : ${PACKAGES_DIR}"
echo "Archive       : ${ARCHIVE}"
[[ -n "$EXTRA_VERSIONS" ]] && echo "Extra versions: ${EXTRA_VERSIONS}"
[[ $FETCH_PROVENANCE -eq 1 ]] && echo "Provenance    : yes"
echo ""

# ── Phase 1: extra-version binary wheels ─────────────────────────────────────
# pip cannot build sdists for a Python version other than the running interpreter,
# so --only-binary :all: is required. Packages with no wheel for a given version
# are silently skipped (expected for some packages).
if [[ -n "$EXTRA_VERSIONS" ]]; then
  echo "Downloading extra-version wheels ..."
  IFS=',' read -ra VER_LIST <<< "$EXTRA_VERSIONS"
  for ver in "${VER_LIST[@]}"; do
    ver="${ver// /}"
    abi="cp$(echo "$ver" | tr -d '.')"
    EXTRA_MISS=0
    echo "  Python ${ver} ..."
    while IFS= read -r line; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" || "$line" == \#* || "$line" == -* ]] && continue
      "$PIP" download \
        --index-url https://libraries.cgr.dev/python/simple/ \
        --only-binary :all: \
        --python-version "$ver" \
        --implementation cp \
        --abi "$abi" \
        --dest "$PACKAGES_DIR" \
        "$line" \
        2>/dev/null || { EXTRA_MISS=$(( EXTRA_MISS + 1 )); true; }
    done < "$REQUIREMENTS"
    [[ $EXTRA_MISS -gt 0 ]] && echo "    (${EXTRA_MISS} package(s) have no wheel for Python ${ver} — skipped)"
  done
  echo ""
fi

# ── Phase 2: primary version ──────────────────────────────────────────────────
echo "Downloading packages ..."

# Download each requirement line individually so a single build failure
# does not abort the rest of the collection.
while IFS= read -r line; do
  # Strip leading/trailing whitespace
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"

  # Skip blank lines, comments, and pip option flags (-r, -c, --index-url, etc.)
  [[ -z "$line" || "$line" == \#* || "$line" == -* ]] && continue

  if "$PIP" download \
      --index-url https://libraries.cgr.dev/python/simple/ \
      --prefer-binary \
      --dest "$PACKAGES_DIR" \
      "$line" \
      2>/tmp/pip-collect-err.txt; then
    : # success — pip already printed progress
  else
    echo "  [FAIL] ${line}"
    echo "$line" >> "$FAILURES_LOG"
    # Append the first error line for context
    grep -m1 'error:\|ValueError:\|ERROR' /tmp/pip-collect-err.txt 2>/dev/null \
      | sed 's/^/         /' || true
    FAILURES=$(( FAILURES + 1 ))
  fi
done < "$REQUIREMENTS"

PKG_COUNT=$(find "$PACKAGES_DIR" -maxdepth 1 -type f \
  \( -name "*.whl" -o -name "*.tar.gz" -o -name "*.zip" \) | wc -l)

echo ""
echo "Packages downloaded : ${PKG_COUNT}"
echo "Failures            : ${FAILURES}"
[[ $FAILURES -gt 0 ]] && echo "Failure log         : ${FAILURES_LOG}"

if [[ $PKG_COUNT -eq 0 ]]; then
  echo ""
  echo "ERROR: no packages downloaded — nothing to archive" >&2
  exit 1
fi

# ── Phase 3: PEP 740 provenance sidecars ─────────────────────────────────────
# URL pattern: libraries.cgr.dev/python/integrity/<pkg>/<version>/<file>/provenance
# Credentials are read from ~/.netrc by curl --netrc.
# Already-present sidecars are counted as OK and skipped.
if [[ $FETCH_PROVENANCE -eq 1 ]]; then
  echo ""
  echo "Fetching provenance sidecars ..."
  ATTEST_OK=0
  ATTEST_MISS=0

  # Parse package name and version from a wheel or sdist filename.
  # Sets global PKG and VER; returns 1 if unparseable.
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
    dest="${dist}.provenance"

    if [[ -f "$dest" ]]; then
      ATTEST_OK=$(( ATTEST_OK + 1 ))
      continue
    fi

    if ! parse_pkg_version "$fn"; then
      echo "  [warn] could not parse pkg/version from ${fn}"
      continue
    fi

    url="https://libraries.cgr.dev/python/integrity/${PKG}/${VER}/${fn}/provenance"
    http_code=$(curl --netrc --silent \
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

  echo "Provenance OK     : ${ATTEST_OK}"
  echo "Provenance missing: ${ATTEST_MISS} (expected for some upstream packages)"
fi

echo ""
echo "Creating archive ..."
tar -czf "$ARCHIVE" -C "$(dirname "$PACKAGES_DIR")" "$(basename "$PACKAGES_DIR")"

CHECKSUM_FILE="${ARCHIVE}.sha256"
sha256sum "$ARCHIVE" > "$CHECKSUM_FILE"

echo ""
echo "=== Done ==="
echo "Archive : ${ARCHIVE}"
echo "SHA-256 : $(cat "$CHECKSUM_FILE")"
[[ $FAILURES -gt 0 ]] && echo "WARNING: ${FAILURES} package(s) failed — review ${FAILURES_LOG}"
echo ""
echo "Transfer both files through the diode, then on the highside run:"
echo "  ./install.sh $(basename "$ARCHIVE") $(basename "$REQUIREMENTS")"
