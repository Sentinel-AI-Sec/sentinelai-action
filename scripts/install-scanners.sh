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
#
# NOTE on `set`: -e is deliberately NOT set. Each install function is guarded
# independently below, so one tool failing to download can never abort the rest
# of the toolchain install (which is exactly what happened when trivy 404'd).
set -uo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GITLEAKS_VERSION=${GITLEAKS_VERSION:-8.18.4}
CHECKOV_VERSION=${CHECKOV_VERSION:-3.2.0}
TRIVY_VERSION=${TRIVY_VERSION:-0.72.0}
OSV_SCANNER_VERSION=${OSV_SCANNER_VERSION:-2.4.0}

TOOLS_DIR=${RUNNER_TEMP:-/tmp}/sentinelai-tools
mkdir -p "$TOOLS_DIR/bin"

# --- checkov: pip package, not a standalone binary ---------------------------
install_checkov() {
  if have checkov; then say "checkov already present"; return 0; fi
  if ! have pip3 && ! have pip; then skip "pip (checkov)"; return 0; fi
  local pip=pip3
  if ! have pip3; then pip=pip; fi
  say "installing checkov==$CHECKOV_VERSION"
  if ! "$pip" install --quiet --disable-pip-version-check "checkov==$CHECKOV_VERSION"; then
    warn "pip install checkov==$CHECKOV_VERSION failed"
    skip "checkov install"
  fi
  return 0
}

# --- gitleaks: tarball from GitHub releases ----------------------------------
install_gitleaks() {
  if have gitleaks; then say "gitleaks already present"; return 0; fi
  say "installing gitleaks $GITLEAKS_VERSION"
  local url="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
  if ! curl -sSfL "$url" -o "$TOOLS_DIR/gitleaks.tar.gz"; then
    warn "gitleaks download failed: $url"
    skip "gitleaks download"
    return 0
  fi
  if ! tar -xzf "$TOOLS_DIR/gitleaks.tar.gz" -C "$TOOLS_DIR/bin" gitleaks; then
    warn "gitleaks unpack failed"
    skip "gitleaks unpack"
  fi
  return 0
}

# --- trivy: official installer, with a direct-tarball fallback ---------------
# The hand-built URL 404'd once in CI, so we try trivy's own installer first
# (it resolves the correct asset itself) and only fall back to the raw tarball.
install_trivy() {
  if have trivy; then say "trivy already present"; return 0; fi

  say "installing trivy $TRIVY_VERSION (official install script)"
  local installer="$TOOLS_DIR/trivy-install.sh"

  if curl -sSfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh -o "$installer"; then
    chmod +x "$installer"
    # bash -x so the installer's own failing command is visible in the CI log
    # instead of collapsing into a silent skip.
    if bash -x "$installer" -b "$TOOLS_DIR/bin" "v${TRIVY_VERSION}"; then
      say "trivy installed via official script"
      return 0
    fi
    warn "official trivy installer failed for v${TRIVY_VERSION}"
  else
    warn "could not download trivy's install.sh"
  fi

  warn "falling back to direct tarball download"
  local url="https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz"
  if ! curl -sSfL "$url" -o "$TOOLS_DIR/trivy.tar.gz"; then
    warn "direct tarball download also failed: $url"
    warn "check that this release asset exists: https://github.com/aquasecurity/trivy/releases/tag/v${TRIVY_VERSION}"
    skip "trivy install"
    return 0
  fi
  if ! tar -xzf "$TOOLS_DIR/trivy.tar.gz" -C "$TOOLS_DIR/bin" trivy; then
    warn "trivy unpack failed"
    skip "trivy unpack"
    return 0
  fi
  say "trivy installed via direct tarball"
  return 0
}

# --- osv-scanner: single static binary ---------------------------------------
install_osv_scanner() {
  if have osv-scanner; then say "osv-scanner already present"; return 0; fi
  say "installing osv-scanner $OSV_SCANNER_VERSION"
  # The fixture checks in a Windows .exe for local use; the runner is Linux.
  local url="https://github.com/google/osv-scanner/releases/download/v${OSV_SCANNER_VERSION}/osv-scanner_linux_amd64"
  if ! curl -sSfL "$url" -o "$TOOLS_DIR/bin/osv-scanner"; then
    warn "osv-scanner download failed: $url"
    warn "check that this release asset exists: https://github.com/google/osv-scanner/releases/tag/v${OSV_SCANNER_VERSION}"
    rm -f "$TOOLS_DIR/bin/osv-scanner"
    skip "osv-scanner download"
  fi
  return 0
}

# Each guarded independently — one tool's failure must never skip the rest.
install_checkov      || warn "install_checkov reported an error, continuing"
install_gitleaks     || warn "install_gitleaks reported an error, continuing"
install_trivy        || warn "install_trivy reported an error, continuing"
install_osv_scanner  || warn "install_osv_scanner reported an error, continuing"

chmod +x "$TOOLS_DIR"/bin/* 2>/dev/null || true

if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "$TOOLS_DIR/bin" >>"$GITHUB_PATH"
fi
export PATH="$TOOLS_DIR/bin:$PATH"

say "toolchain ready in $TOOLS_DIR/bin"

# Always report what actually landed. Without this, a missing tool only shows up
# much later as an empty SARIF file, which is far harder to trace back.
say "--- toolchain verification ---"
for tool in trivy checkov osv-scanner gitleaks; do
  if have "$tool"; then
    say "  OK   $tool: $("$tool" --version 2>&1 | head -1)"
  else
    warn "  MISS $tool: not on PATH after install"
  fi
done