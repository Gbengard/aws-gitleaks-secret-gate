#!/usr/bin/env bash
# Scans the full Git history behind the commit being built.
# Exit 0 = clean. Any other exit code stops the pipeline.
set -uo pipefail

GITLEAKS_VERSION="${GITLEAKS_VERSION:?GITLEAKS_VERSION is not set}"
GITLEAKS_SHA256="${GITLEAKS_SHA256:?GITLEAKS_SHA256 is not set}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
REPORT="${REPORT_PATH:-gitleaks-report.json}"
CONFIG=".gitleaks.toml"

fail() { echo "ERROR: $*" >&2; exit 2; }

# 1. Install a pinned Gitleaks and check its checksum.
TARBALL="gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
URL="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/${TARBALL}"
TMP="$(mktemp -d)"
echo "Downloading Gitleaks ${GITLEAKS_VERSION}"
curl -sSfL -o "${TMP}/${TARBALL}" "${URL}" || fail "could not download ${URL}"
echo "${GITLEAKS_SHA256}  ${TMP}/${TARBALL}" | sha256sum -c - >/dev/null \
  || fail "checksum of the Gitleaks download does not match"
tar -xzf "${TMP}/${TARBALL}" -C "${TMP}" gitleaks
install -m 0755 "${TMP}/gitleaks" "${INSTALL_DIR}/gitleaks" || fail "could not install Gitleaks"

# 2. Refuse to scan a partial history. A shallow clone would hide old commits.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || fail "this is not a Git repository. Set the Source action to Full clone."
if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
  fail "the clone is shallow, so the scan would miss old commits."
fi
echo "Scanning $(git rev-list --count HEAD) commit(s) reachable from $(git rev-parse --short HEAD)"

# 3. Scan. --redact keeps the secret out of the log and the report.
CONFIG_ARGS=()
[ -f "${CONFIG}" ] && CONFIG_ARGS=(--config "${CONFIG}")
"${INSTALL_DIR}/gitleaks" git . \
  --log-opts="HEAD" \
  --redact --no-banner --exit-code 1 \
  --report-format json --report-path "${REPORT}" \
  "${CONFIG_ARGS[@]}"
STATUS=$?

# 4. Keep the report, even when the scan failed.
if [ -n "${ARTIFACT_BUCKET:-}" ] && [ -f "${REPORT}" ]; then
  KEY="reports/${CODEBUILD_BUILD_NUMBER:-local}/gitleaks-report.json"
  aws s3 cp "${REPORT}" "s3://${ARTIFACT_BUCKET}/${KEY}" --only-show-errors \
    && echo "Report saved to s3://${ARTIFACT_BUCKET}/${KEY}" \
    || echo "WARNING: could not save the report" >&2
fi

# 5. Result.
if [ "${STATUS}" -eq 0 ]; then
  echo "No secrets found. The scan passed."
  exit 0
fi
if [ "${STATUS}" -eq 1 ]; then
  echo "SECRETS FOUND. The pipeline is blocked. Rotate the secret, then fix the history."
  python3 - "${REPORT}" <<'PY' || true
import json, sys
for f in json.load(open(sys.argv[1])):
    print(f"  rule={f['RuleID']} file={f['File']} line={f['StartLine']} commit={f['Commit'][:8]}")
    print(f"  fingerprint={f['Fingerprint']}")
PY
  exit 1
fi
fail "Gitleaks stopped with exit code ${STATUS}. Treating this as a failed scan."
