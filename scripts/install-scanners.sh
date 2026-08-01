#!/usr/bin/env bash
# Install the scanner toolchain at pinned versions.
#
# Pinning is the point: an unpinned tool updates one day and the findings change
# with no code change, which is very hard to debug. The versions default to what
# sentinelai-fixtures was authored against.
#
# Scope note: SEC-11 only needs the tools to be present. Making each scanner
# produce good output — and proving Roslyn catches CWE-502 on the fixture — is
# SEC-12's job.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GITLEAKS_VERSION=${GITLEAKS_VERSION:-8.18.4}
CHECKOV_VERSION=${CHECKOV_VERSION:-3.2.0}
TRIVY_VERSION=${TRIVY_VERSION:-0.55.0}
OSV_SCANNER_VERSION=${OSV_SCANNER_VERSION:-2.3.8}

TOOLS_DIR=${RUNNER_TEMP:-/tmp}/sentinelai-tools
mkdir -p "$TOOLS_DIR/bin"

install_checkov() {
  if have checkov; then say "checkov already present"; return; fi
  if ! have pip3 && ! have pip; then skip "pip (checkov)"; return; fi
  local pip=pip3
  if ! have pip3; then pip=pip; fi
  say "installing checkov==$CHECKOV_VERSION"
  "$pip" install --quiet --disable-pip-version-check "checkov==$CHECKOV_VERSION" \
    || skip "checkov install"
}

install_gitleaks() {
  if have gitleaks; then say "gitleaks already present"; return; fi
  say "installing gitleaks $GITLEAKS_VERSION"
  local url="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
  curl -sSfL "$url" -o "$TOOLS_DIR/gitleaks.tar.gz" \
    && tar -xzf "$TOOLS_DIR/gitleaks.tar.gz" -C "$TOOLS_DIR/bin" gitleaks \
    || skip "gitleaks download"
}

install_trivy() {
  if have trivy; then say "trivy already present"; return; fi
  say "installing trivy $TRIVY_VERSION"
  local url="https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz"
  curl -sSfL "$url" -o "$TOOLS_DIR/trivy.tar.gz" \
    && tar -xzf "$TOOLS_DIR/trivy.tar.gz" -C "$TOOLS_DIR/bin" trivy \
    || skip "trivy download"
}

install_osv_scanner() {
  if have osv-scanner; then say "osv-scanner already present"; return; fi
  say "installing osv-scanner $OSV_SCANNER_VERSION"
  # The fixture checks in a Windows .exe for local use; the runner is Linux.
  local url="https://github.com/google/osv-scanner/releases/download/v${OSV_SCANNER_VERSION}/osv-scanner_linux_amd64"
  curl -sSfL "$url" -o "$TOOLS_DIR/bin/osv-scanner" || skip "osv-scanner download"
}

install_checkov
install_gitleaks
install_trivy
install_osv_scanner

chmod +x "$TOOLS_DIR"/bin/* 2>/dev/null || true
if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "$TOOLS_DIR/bin" >>"$GITHUB_PATH"
fi
export PATH="$TOOLS_DIR/bin:$PATH"

say "toolchain ready in $TOOLS_DIR/bin"
