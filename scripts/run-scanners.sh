#!/usr/bin/env bash
# Run the scanners and write their raw output into bundle/findings/.
#
# The toolchain mirrors sentinelai-fixtures/scripts/*.sh one for one — same
# tools, same flags, same output filenames. When the fixture's scripts change,
# these commands change with them, or the bundle stops matching what the fixture
# was authored to produce.
#
#   roslyn.sarif          Security Code Scan, inside `dotnet build`   (code)
#   osv.sarif             OSV-Scanner against packages.lock.json      (dep)
#   trivy.sarif           Trivy fs, misconfig + vuln                  (infra/dep)
#   checkov_infra.sarif   Checkov against the Terraform directory     (infra)
#   checkov_docker.sarif  Checkov against the Dockerfile              (infra)
#
# Every scanner is wrapped so a missing tool or a non-zero exit costs us that
# tool's findings and nothing else — one broken scanner must not fail the job.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCAN_DIR=$(workspace_path "${SCAN_DIR:-.}")
BUNDLE_DIR=$(workspace_path "${BUNDLE_DIR:-sentinelai-bundle}")
INFRA_DIR="$SCAN_DIR/${INFRA_DIR:-infra}"
DOTNET_PROJECT=${DOTNET_PROJECT:-}
LOCKFILE_PATH=${LOCKFILE_PATH:-}
SCS_VERSION=${SCS_VERSION:-5.6.7}
FINDINGS="$BUNDLE_DIR/findings"
TMP=${RUNNER_TEMP:-/tmp}/sentinelai-scan

mkdir -p "$FINDINGS" "$TMP"

ran=()
missing=()

# --- code layer: Roslyn / Security Code Scan ---------------------------------
# Not a standalone CLI: it runs as an analyzer inside the .NET build, and the
# build writes its warnings out as SARIF. The same build also produces the lock
# file OSV-Scanner needs, so this runs first.
run_roslyn() {
  if [[ -z "$DOTNET_PROJECT" ]]; then
    say "no dotnet-project given — skipping the code layer"
    missing+=(roslyn-security)
    return
  fi
  local proj
  proj=$(workspace_path "$DOTNET_PROJECT")
  if [[ ! -f "$proj" ]]; then
    warn "dotnet-project $proj not found"
    missing+=(roslyn-security)
    return
  fi
  if ! have dotnet; then skip "dotnet SDK"; missing+=(roslyn-security); return; fi

  say "roslyn: building $proj with SecurityCodeScan $SCS_VERSION"
  local out="$FINDINGS/roslyn.sarif"
  (
    cd "$(dirname "$proj")"
    export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
    dotnet add "$proj" package SecurityCodeScan.VS2019 --version "$SCS_VERSION"
    # --use-lock-file so the dep layer has a lock file to scan afterwards.
    dotnet restore "$proj" --use-lock-file
    # %3Bversion%3D2.1 is an escaped ";version=2.1" — it asks MSBuild for SARIF
    # v2.1 rather than the v1 default. -p: not /p:, which MSYS mangles on Windows.
    dotnet build "$proj" --no-restore --nologo -v quiet \
      "-p:ErrorLog=${out}%3Bversion%3D2.1" \
      -p:RunAnalyzersDuringBuild=true \
      -p:TreatWarningsAsErrors=false
  ) || warn "dotnet build reported an error — continuing with whatever SARIF it wrote"

  if [[ -s "$out" ]]; then ran+=(roslyn-security); else rm -f "$out"; missing+=(roslyn-security); fi
}

# --- dependency layer: OSV-Scanner -------------------------------------------
run_osv() {
  if ! have osv-scanner; then skip osv-scanner; missing+=(osv-scanner); return; fi

  local lock="$LOCKFILE_PATH"
  if [[ -n "$lock" ]]; then
    lock=$(workspace_path "$lock")
  else
    # The build above usually just wrote one; find it rather than guess a path.
    lock=$(find "$SCAN_DIR" -name packages.lock.json -not -path '*/bin/*' -not -path '*/obj/*' -print -quit)
  fi
  if [[ -z "$lock" || ! -f "$lock" ]]; then
    warn "no packages.lock.json found — run the .NET restore first, or set lockfile-path"
    missing+=(osv-scanner)
    return
  fi

  say "osv-scanner: scanning $lock"
  # Exit code 1 means "vulnerabilities found", which is the expected case here.
  osv-scanner --format sarif --output-file "$FINDINGS/osv.sarif" --lockfile "$lock" || true
  if [[ -s "$FINDINGS/osv.sarif" ]]; then ran+=(osv-scanner); else rm -f "$FINDINGS/osv.sarif"; missing+=(osv-scanner); fi
}

# --- infra layer: Trivy -------------------------------------------------------
run_trivy() {
  if ! have trivy; then skip trivy; missing+=(trivy); return; fi
  say "trivy: fs scan of $SCAN_DIR (misconfig + vuln)"
  trivy fs --scanners misconfig,vuln --format sarif -o "$FINDINGS/trivy.sarif" \
    --exit-code 0 "$SCAN_DIR" || true
  if [[ -s "$FINDINGS/trivy.sarif" ]]; then ran+=(trivy); else rm -f "$FINDINGS/trivy.sarif"; missing+=(trivy); fi
}

# --- infra layer: Checkov, twice ---------------------------------------------
# Terraform and the Dockerfile are separate Checkov runs producing separate
# SARIF files, exactly as the fixture does it — a single combined run drops the
# Dockerfile findings.
checkov_run() {
  local label=$1 outfile=$2
  shift 2
  # ${TMP:?} so an unset TMP can never turn this into `rm -rf /...`.
  rm -rf "${TMP:?}/${label:?}"
  checkov "$@" --output sarif --output-file-path "$TMP/$label" --quiet || true
  # Checkov names the file results_sarif.sarif; older builds used results.sarif.
  local produced=""
  for candidate in "$TMP/$label/results_sarif.sarif" "$TMP/$label/results.sarif"; do
    if [[ -f "$candidate" ]]; then produced=$candidate; break; fi
  done
  if [[ -n "$produced" ]]; then
    mv "$produced" "$FINDINGS/$outfile"
    return 0
  fi
  return 1
}

run_checkov() {
  if ! have checkov; then skip checkov; missing+=(checkov); return; fi
  local any=1

  if [[ -d "$INFRA_DIR" ]]; then
    say "checkov: scanning $INFRA_DIR"
    if checkov_run checkov_infra checkov_infra.sarif --directory "$INFRA_DIR"; then any=0; fi
  else
    warn "no infra dir at $INFRA_DIR — skipping the Terraform Checkov run"
  fi

  local dockerfile="$SCAN_DIR/Dockerfile"
  if [[ -f "$dockerfile" ]]; then
    say "checkov: scanning $dockerfile"
    if checkov_run checkov_docker checkov_docker.sarif --file "$dockerfile"; then any=0; fi
  else
    warn "no Dockerfile at $dockerfile — skipping the Dockerfile Checkov run"
  fi

  if [[ $any -eq 0 ]]; then ran+=(checkov); else missing+=(checkov); fi
}

run_roslyn
run_osv
run_trivy
run_checkov

# Record what ran, at which version. The backend stores this as provenance, so a
# finding can always be traced back to a known tool version.
{
  printf '{\n'
  printf '  "roslyn-security": "%s",\n' "$(json_escape "$SCS_VERSION")"
  printf '  "osv-scanner": "%s",\n'     "$(json_escape "${OSV_SCANNER_VERSION:-unknown}")"
  printf '  "trivy": "%s",\n'           "$(json_escape "${TRIVY_VERSION:-unknown}")"
  printf '  "checkov": "%s",\n'         "$(json_escape "${CHECKOV_VERSION:-unknown}")"
  printf '  "gitleaks": "%s"\n'         "$(json_escape "${GITLEAKS_VERSION:-unknown}")"
  printf '}\n'
} >"$BUNDLE_DIR/scanner-versions.json"

if [[ ${#ran[@]} -eq 0 ]]; then
  warn "no scanner produced findings — the bundle will carry graph inputs only"
else
  say "scanners that produced output: ${ran[*]}"
fi

if [[ ${#missing[@]} -gt 0 ]]; then
  warn "scanners with no output: ${missing[*]}"
fi
