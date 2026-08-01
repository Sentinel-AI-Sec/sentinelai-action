#!/usr/bin/env bash
# Bundle-shape tests for SEC-11.
#
# Runs the assembly scripts against a checkout of sentinelai-fixtures and checks
# what came out. Scanners do not have to be installed: with none present the
# bundle still has to be well formed and still has to contain no source, which
# is exactly the degraded case worth testing.
#
# Usage: FIXTURE_DIR=/path/to/sentinelai-fixtures bash test/bundle-shape.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FIXTURE_DIR=${FIXTURE_DIR:-}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no()   { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else no "$1"; fi; }

if [[ -z "$FIXTURE_DIR" || ! -d "$FIXTURE_DIR" ]]; then
  echo "FIXTURE_DIR must point at a checkout of Sentinel-AI-Sec/sentinelai-fixtures" >&2
  exit 2
fi

# The scripts address everything through GITHUB_WORKSPACE, so pointing it at a
# copy of the fixture is all it takes to run them outside Actions.
cp -r "$FIXTURE_DIR" "$WORK/repo"
export GITHUB_WORKSPACE="$WORK/repo"
export RUNNER_TEMP="$WORK/tmp"
export GITHUB_SHA="0123456789abcdef0123456789abcdef01234567"
export GITHUB_REF="refs/pull/1/head"
unset GITHUB_OUTPUT GITHUB_STEP_SUMMARY GITHUB_PATH
mkdir -p "$RUNNER_TEMP"

BUNDLE="$GITHUB_WORKSPACE/sentinelai-bundle"

echo "== assembling bundle from $FIXTURE_DIR =="
SCAN_DIR=. BUNDLE_DIR=sentinelai-bundle \
  bash "$ROOT/scripts/secret-prescan.sh" >"$WORK/prescan.log" 2>&1 || true
SCAN_DIR=. INFRA_DIR=infra BUNDLE_DIR=sentinelai-bundle DOTNET_PROJECT="" \
  bash "$ROOT/scripts/run-scanners.sh" >"$WORK/scanners.log" 2>&1 || true
SCAN_DIR=. INFRA_DIR=infra BUNDLE_DIR=sentinelai-bundle \
  bash "$ROOT/scripts/collect-graph-inputs.sh" >"$WORK/graph.log" 2>&1 || true
BUNDLE_DIR=sentinelai-bundle PROJECT_ID=test-project RUNNER_SECRET_SCAN=passed \
  bash "$ROOT/scripts/build-metadata.sh" >"$WORK/metadata.log" 2>&1

echo
echo "== bundle layout =="
(cd "$BUNDLE" && find . -type f | sort | sed 's/^/  /')
echo

echo "== graph inputs (SEC-11 acceptance: the backend can build edges) =="
check "terraform source collected"      '[[ $(find "$BUNDLE/graph-inputs" -name "*.tf" | wc -l) -ge 5 ]]'
check "iam.tf collected (role->resource edges)" '[[ -f "$BUNDLE/graph-inputs/infra/iam.tf" ]]'
check "Dockerfile collected (code->infra join)" '[[ -f "$BUNDLE/graph-inputs/Dockerfile" ]]'
check "csproj collected (dep->code seam)"       '[[ -f "$BUNDLE/graph-inputs/src/OrderApp/OrderApp.csproj" ]]'
check "packages.lock.json collected"            '[[ -f "$BUNDLE/graph-inputs/src/OrderApp/packages.lock.json" ]]'

echo
echo "== provenance =="
check "metadata.json written"           '[[ -f "$BUNDLE/metadata.json" ]]'
check "scanner-versions.json written"   '[[ -f "$BUNDLE/scanner-versions.json" ]]'
# Windows ships a python3 shim that resolves but does not run, so test the
# interpreter rather than the name.
if python3 -c 'pass' >/dev/null 2>&1; then
  check "metadata.json is valid JSON"   'python3 -m json.tool "$BUNDLE/metadata.json" >/dev/null'
  check "scanner-versions is valid JSON" 'python3 -m json.tool "$BUNDLE/scanner-versions.json" >/dev/null'
  check "artifact manifest is non-empty" '[[ $(python3 -c "import json;print(len(json.load(open(\"$BUNDLE/metadata.json\"))[\"artifacts\"]))") -gt 0 ]]'
  check "commit_sha recorded"            'python3 -c "import json;assert json.load(open(\"$BUNDLE/metadata.json\"))[\"commit_sha\"]"'
else
  echo "  skip python3 not available — JSON validity unchecked"
fi

echo
echo "== the core promise: no application source leaves the runner =="
check "no .cs in the bundle directory"  '! find "$BUNDLE" -name "*.cs" | grep -q .'
check "no compiled app output either"   '! find "$BUNDLE" -name "*.dll" | grep -q .'
check "source guard passes on the dir"  'TARGET=sentinelai-bundle bash "$ROOT/scripts/assert-no-source.sh" >/dev/null 2>&1'

# The guard is only worth having if it actually trips. Plant a .cs file and
# require a refusal — a guard that never fails is indistinguishable from none.
cp "$GITHUB_WORKSPACE/src/OrderApp/Program.cs" "$BUNDLE/graph-inputs/Program.cs"
check "source guard REFUSES a planted .cs" '! TARGET=sentinelai-bundle bash "$ROOT/scripts/assert-no-source.sh" >/dev/null 2>&1'
rm -f "$BUNDLE/graph-inputs/Program.cs"

echo
echo "== packaging =="
check "bundle packages"                 'BUNDLE_DIR=sentinelai-bundle bash "$ROOT/scripts/package-bundle.sh" >/dev/null 2>&1'
check "tarball exists"                  '[[ -f "$BUNDLE.tar.gz" ]]'
check "no .cs inside the tarball"       '! tar -tzf "$BUNDLE.tar.gz" | grep -q "\.cs$"'

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
