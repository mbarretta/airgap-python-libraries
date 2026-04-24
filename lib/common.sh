#!/usr/bin/env bash
# =============================================================================
# common.sh — shared helpers for enumerate.sh, collect.sh, install.sh
# =============================================================================
# Source from sibling scripts:
#   source "${SCRIPT_DIR}/lib/common.sh"
# =============================================================================

readonly CG_PYTHON_HOST="libraries.cgr.dev"
readonly CG_PYTHON_INDEX="https://${CG_PYTHON_HOST}/python/simple/"
readonly CG_PYTHON_INTEGRITY="https://${CG_PYTHON_HOST}/python/integrity"

verify_netrc() {
  python3 - "$CG_PYTHON_HOST" <<'PY'
import netrc, sys
host = sys.argv[1]
try:
    entry = netrc.netrc().authenticators(host)
except FileNotFoundError:
    entry = None
if not entry:
    print(f"ERROR: no credentials for {host} in ~/.netrc", file=sys.stderr)
    print("", file=sys.stderr)
    print("Add them with:", file=sys.stderr)
    print("  chainctl auth pull-token create --repository=python --ttl=8760h", file=sys.stderr)
    print("  # Then append to ~/.netrc:", file=sys.stderr)
    print(f"  machine {host}", file=sys.stderr)
    print("  login    <username>", file=sys.stderr)
    print("  password <password>", file=sys.stderr)
    print("  chmod 600 ~/.netrc", file=sys.stderr)
    sys.exit(1)
PY
}

find_pip() {
  local pip
  pip=$(command -v pip3 2>/dev/null || command -v pip 2>/dev/null || true)
  if [[ -z "$pip" ]]; then
    echo "ERROR: pip / pip3 not found on PATH" >&2
    echo "       Install with: sudo apt-get install -y python3-pip" >&2
    return 1
  fi
  echo "$pip"
}

find_packages() {
  find "$1" -maxdepth 1 -type f \
    \( -name "*.whl" -o -name "*.tar.gz" -o -name "*.zip" \)
}
