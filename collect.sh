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
source "${SCRIPT_DIR}/lib/common.sh"

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

verify_netrc

PIP=$(find_pip) || exit 1

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

ERR_TMP=$(mktemp)
trap 'rm -f "$ERR_TMP"' EXIT

read_requirements() {
  awk '
    { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "") }
    NF && !/^#/ && !/^-/
  ' "$1"
}

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
      "$PIP" download \
        --index-url "$CG_PYTHON_INDEX" \
        --only-binary :all: \
        --python-version "$ver" \
        --implementation cp \
        --abi "$abi" \
        --dest "$PACKAGES_DIR" \
        "$line" \
        2>/dev/null || EXTRA_MISS=$(( EXTRA_MISS + 1 ))
    done < <(read_requirements "$REQUIREMENTS")
    [[ $EXTRA_MISS -gt 0 ]] && echo "    (${EXTRA_MISS} package(s) have no wheel for Python ${ver} — skipped)"
  done
  echo ""
fi

# ── Phase 2: primary version ──────────────────────────────────────────────────
echo "Downloading packages ..."

# Download each requirement line individually so a single build failure
# does not abort the rest of the collection.
while IFS= read -r line; do
  if "$PIP" download \
      --index-url "$CG_PYTHON_INDEX" \
      --prefer-binary \
      --dest "$PACKAGES_DIR" \
      "$line" \
      2>"$ERR_TMP"; then
    continue
  fi
  echo "  [FAIL] ${line}"
  echo "$line" >> "$FAILURES_LOG"
  grep -m1 'error:\|ValueError:\|ERROR' "$ERR_TMP" 2>/dev/null \
    | sed 's/^/         /' || true
  FAILURES=$(( FAILURES + 1 ))
done < <(read_requirements "$REQUIREMENTS")

PKG_COUNT=$(find_packages "$PACKAGES_DIR" | wc -l)

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
# URL pattern: ${CG_PYTHON_INTEGRITY}/<pkg>/<version>/<file>/provenance
# Credentials are read from ~/.netrc by curl --netrc.
# Already-present sidecars are counted as OK and skipped.
if [[ $FETCH_PROVENANCE -eq 1 ]]; then
  echo ""
  echo "Fetching provenance sidecars ..."
  ATTEST_OK=0
  ATTEST_MISS=0

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

  CURL_CONFIG=$(mktemp)
  NEW_DESTS=()

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

    printf 'url = "%s"\noutput = "%s"\n' \
      "${CG_PYTHON_INTEGRITY}/${PKG}/${VER}/${fn}/provenance" \
      "$dest" \
      >> "$CURL_CONFIG"
    NEW_DESTS+=("$dest")
  done < <(find_packages "$PACKAGES_DIR" | sort)

  if [[ ${#NEW_DESTS[@]} -gt 0 ]]; then
    # --parallel fans out across URLs; zero-byte outputs (404s and transport
    # errors) are deleted below and counted as missing.
    curl --netrc --silent --parallel --parallel-max 8 --config "$CURL_CONFIG" \
      2>/dev/null || true

    for dest in "${NEW_DESTS[@]}"; do
      if [[ -s "$dest" ]]; then
        ATTEST_OK=$(( ATTEST_OK + 1 ))
      else
        rm -f "$dest"
        ATTEST_MISS=$(( ATTEST_MISS + 1 ))
      fi
    done
  fi

  rm -f "$CURL_CONFIG"

  echo "Provenance OK     : ${ATTEST_OK}"
  echo "Provenance missing: ${ATTEST_MISS} (expected for some upstream packages)"
fi

echo ""
echo "Creating archive ..."
if command -v pigz >/dev/null 2>&1; then
  tar --use-compress-program=pigz -cf "$ARCHIVE" \
    -C "$(dirname "$PACKAGES_DIR")" "$(basename "$PACKAGES_DIR")"
else
  tar -czf "$ARCHIVE" -C "$(dirname "$PACKAGES_DIR")" "$(basename "$PACKAGES_DIR")"
fi

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
