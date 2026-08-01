#!/usr/bin/env bash
# Secret pre-scan: look for credentials in the repository *before* anything
# leaves the runner.
#
# The raw Gitleaks report is deliberately NOT put in the bundle — it quotes the
# secrets it finds, so shipping it would leak exactly what the pre-scan exists to
# catch. Only the status travels, which is all `scan_bundles.runner_secret_scan`
# records. The backend still applies its own guaranteed ingress redaction.
#
# Status values: passed | findings | skipped
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCAN_DIR=$(workspace_path "${SCAN_DIR:-.}")
BUNDLE_DIR=$(workspace_path "${BUNDLE_DIR:-sentinelai-bundle}")
REPORT=${RUNNER_TEMP:-/tmp}/gitleaks.json

mkdir -p "$BUNDLE_DIR"

status="skipped"
if have gitleaks; then
  # --exit-code 0 so a hit records rather than kills the run: the developer sees
  # it in the log, and the backend is told the pre-scan was not clean.
  if gitleaks detect \
      --source "$SCAN_DIR" \
      --report-format json \
      --report-path "$REPORT" \
      --redact \
      --no-banner \
      --exit-code 0; then
    if [[ -s "$REPORT" ]] && ! grep -q '^\[\s*\]$' "$REPORT"; then
      count=$(grep -c '"RuleID"' "$REPORT" || true)
      status="findings"
      warn "gitleaks reported ${count:-some} potential secret(s); the report stays on the runner"
    else
      status="passed"
      say "gitleaks pre-scan clean"
    fi
  else
    warn "gitleaks failed to run"
  fi
else
  skip "gitleaks"
fi

rm -f "$REPORT"
set_output "status" "$status"
say "runner_secret_scan=$status"
