# Chainguard Libraries — Python Packages via Diode Transfer

The simplest path for moving Python packages into an air-gapped environment:
enumerate the catalog (or bring your own `requirements.txt`), download wheels
and sdists into a flat directory, tar it up, carry it across, install from local
files. No S3, no registry server, no extra tooling.

---

## How it works

`enumerate.sh` queries the Chainguard Libraries PEP 503 simple index to
produce a `requirements.txt` of every available package. `collect.sh` downloads
the full transitive dependency tree into a flat `packages/` directory and
archives it for transfer. `install.sh` extracts and installs on the highside
without any network access.

```
LOWSIDE                                    ONE-WAY DIODE         HIGHSIDE
────────────────────────────────────────   ─────────────         ──────────────────
./enumerate.sh → requirements.txt                           pip install
./collect.sh requirements.txt                                      --no-index
  → packages/                             packages.tgz  ──►        --find-links packages/
```

---

## Prerequisites

**Lowside machine**
- Python 3 + pip (`sudo apt-get install -y python3-pip`)
- curl (`sudo apt-get install -y curl`)
- A Chainguard pull token and `~/.netrc` configured (see Setup below)
- Build toolchain for packages that ship only as source distributions:
  ```bash
  sudo apt-get install -y build-essential gfortran pkg-config python3-dev
  ```
  Only needed if requirements include packages without pre-built wheels (common
  in scientific stacks).
- Optional: `pigz` (`sudo apt-get install -y pigz`) for multi-threaded gzip
  compression of the transfer archive. `collect.sh` uses it automatically when
  present; output is still plain `.tgz` and unpacks with `tar -xf` on the highside.

**Highside machine**
- Python 3 + pip
- No network access required

---

## Setup (one-time, lowside)

Create a Chainguard pull token for the Python repository:

```bash
chainctl auth pull-token create --repository=python --ttl=8760h
```

This prints a `username` and `password`. Add them to `~/.netrc`:

```
machine libraries.cgr.dev
login    <username>
password <password>
```

```bash
chmod 600 ~/.netrc
```

pip and curl both read `~/.netrc` automatically — no credentials are embedded in
URLs or config files. See [Chainguard's build configuration docs](https://edu.chainguard.dev/chainguard/libraries/python/build-configuration/)
for full details.

---

## Step 0 — Enumerate packages (optional, lowside)

To collect the full Chainguard Python catalog rather than a hand-curated list,
generate `requirements.txt` automatically:

```bash
./enumerate.sh
```

This queries the PEP 503 simple index at `libraries.cgr.dev/python/simple/`
and writes one package name per line to `requirements.txt`. Feed it directly
into `collect.sh`.

Skip this step if you already have a `requirements.txt`.

---

## Step 1 — Collect (lowside)

```bash
./collect.sh requirements.txt
```

Downloads all packages (including transitive dependencies) into `packages/` and
creates a timestamped archive:

```
packages-20260424-120000.tgz
packages-20260424-120000.tgz.sha256
```

**Re-runs are incremental.** `pip download` skips files already present in
`packages/`, so only new or updated packages are fetched.

### Multiple Python versions

By default `pip download` fetches wheels compatible with the running interpreter.
If the highside uses a different Python version (or multiple versions), pass
`--extra-python-versions`:

```bash
./collect.sh requirements.txt --extra-python-versions 3.11,3.12
```

This adds a pass per listed version using `--only-binary :all:` — only pre-built
wheels are collected for those versions. Packages with no wheel for a given
version are silently skipped. All wheels land in the same `packages/` directory.

### PEP 740 provenance sidecars

To include `.provenance` attestation files for offline use with
`pypi-attestations verify` on the highside, add `--provenance`:

```bash
./collect.sh requirements.txt --provenance
```

Sidecars are fetched from `libraries.cgr.dev/python/integrity` and written
alongside each artifact as `<filename>.provenance`. They are included in the
transfer archive. Packages without a provenance record are counted and skipped
without failing the run.

### Combining options

```bash
./collect.sh requirements.txt --extra-python-versions 3.11,3.12 --provenance
```

---

## Step 2 — Transfer

Copy both files through the diode:

```
packages-<timestamp>.tgz
packages-<timestamp>.tgz.sha256
```

---

## Step 3 — Install (highside)

```bash
./install.sh packages-20260424-120000.tgz requirements.txt
```

The script:
1. Verifies the SHA-256 checksum (if the sidecar is present)
2. Extracts the archive to `packages/`
3. Runs `pip install --no-index --find-links packages/ -r requirements.txt`

No index server is contacted.

---

## Ongoing use — delta updates

Re-run on the same `packages/` directory whenever requirements change or you
want to pick up Chainguard's latest CVE-remediated versions. Only new or changed
packages are fetched.

```bash
./enumerate.sh            # refresh the full catalog list (optional)
./collect.sh requirements.txt
# Transfer and install the new archive on the highside
```

---

## Using the packages

After `install.sh` completes, packages are installed into whichever Python
environment pip resolved to. For a virtual environment:

```bash
python3 -m venv .venv
source .venv/bin/activate
./install.sh packages-<timestamp>.tgz requirements.txt
```

---

## Notes

### Why no PEP 503 index server?

`pip install --find-links` resolves packages by filename from a local directory
— no index server is needed on the highside. For environments that require a
full PEP 503 index (Poetry, some CI tooling), see
[`dir2pi`](https://github.com/wolever/pip2pi)

### Build failures

Some packages ship only as source distributions and require a native build
toolchain. A single build failure does not abort the collection — `collect.sh`
logs it with a one-line error summary and continues. Review
`<archive-name>-<timestamp>.failures.txt` after the run to triage packages that
have no binary wheel for your Python version.
