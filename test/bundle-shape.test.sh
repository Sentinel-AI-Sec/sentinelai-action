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
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

# check     <label> <command...>  — passes when the command succeeds
# check_not <label> <command...>  — passes when the command fails
check() {
  local label=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else no "$label"; fi
}
check_not() {
  local label=$1
  shift
  if "$@" >/dev/null 2>&1; then no "$label"; else ok "$label"; fi
}

# Predicates, so every check is a plain command rather than a string to eval.
found_any()   { [[ -n $(find "$1" -name "$2" -print -quit) ]]; }
found_count() { [[ $(find "$2" -name "$3" | wc -l) -ge $1 ]]; }
json_valid()  { python3 -m json.tool "$1"; }
tarball_readable() { tar -tzf "$1" >/dev/null 2>&1; }
tarball_has()      { tar -tzf "$1" | grep -q "$2"; }
manifest_non_empty() {
  local n
  n=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))['artifacts']))" "$1")
  [[ $n -gt 0 ]]
}
field_set() {
  python3 -c "import json,sys; assert json.load(open(sys.argv[1]))[sys.argv[2]]" "$1" "$2"
}
guard() { TARGET=$1 bash "$ROOT/scripts/assert-no-source.sh"; }

# A function, not `env BUNDLE_DIR=... bash ...`. `check` invokes "$@", and an
# assignment prefix is not applied through "$@" — bash looks for a command
# literally named `BUNDLE_DIR=sentinelai-bundle` and fails. `env` was there to
# make that work, which it does, at the price of letting any `env` earlier on
# PATH decide whether the tarball is built at all. A function needs neither.
package_bundle() { BUNDLE_DIR=sentinelai-bundle bash "$ROOT/scripts/package-bundle.sh"; }

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
GRAPH="$BUNDLE/graph-inputs"

echo "== assembling bundle from $FIXTURE_DIR =="
SCAN_DIR=. BUNDLE_DIR=sentinelai-bundle \
  bash "$ROOT/scripts/secret-prescan.sh" >"$WORK/prescan.log" 2>&1
SCAN_DIR=. INFRA_DIR=infra BUNDLE_DIR=sentinelai-bundle DOTNET_PROJECT="" \
  bash "$ROOT/scripts/run-scanners.sh" >"$WORK/scanners.log" 2>&1
SCAN_DIR=. INFRA_DIR=infra BUNDLE_DIR=sentinelai-bundle \
  bash "$ROOT/scripts/collect-graph-inputs.sh" >"$WORK/graph.log" 2>&1
BUNDLE_DIR=sentinelai-bundle PROJECT_ID=test-project RUNNER_SECRET_SCAN=passed \
  bash "$ROOT/scripts/build-metadata.sh" >"$WORK/metadata.log" 2>&1

echo
echo "== bundle layout =="
(cd "$BUNDLE" && find . -type f | sort | sed 's/^/  /')
echo

echo "== graph inputs (SEC-11 acceptance: the backend can build edges) =="
check "terraform source collected"              found_count 5 "$GRAPH" '*.tf'
check "iam.tf collected (role->resource edges)" test -f "$GRAPH/infra/iam.tf"
check "Dockerfile collected (code->infra join)" test -f "$GRAPH/Dockerfile"
check "csproj collected (dep->code seam)"       test -f "$GRAPH/src/OrderApp/OrderApp.csproj"
check "packages.lock.json collected"            test -f "$GRAPH/src/OrderApp/packages.lock.json"

echo
echo "== provenance =="
check "metadata.json written"         test -f "$BUNDLE/metadata.json"
check "scanner-versions.json written" test -f "$BUNDLE/scanner-versions.json"
# Windows ships a python3 shim that resolves but does not run, so test the
# interpreter rather than the name.
if python3 -c 'pass' >/dev/null 2>&1; then
  check "metadata.json is valid JSON"     json_valid "$BUNDLE/metadata.json"
  check "scanner-versions is valid JSON"  json_valid "$BUNDLE/scanner-versions.json"
  check "artifact manifest is non-empty"  manifest_non_empty "$BUNDLE/metadata.json"
  check "commit_sha recorded"             field_set "$BUNDLE/metadata.json" commit_sha
else
  echo "  skip python3 not available — JSON validity unchecked"
fi

echo
echo "== the core promise: no application source leaves the runner =="
check_not "no .cs in the bundle directory" found_any "$BUNDLE" '*.cs'
check_not "no compiled app output either"  found_any "$BUNDLE" '*.dll'
check     "source guard passes on the dir" guard sentinelai-bundle

# The guard is only worth having if it actually trips. Plant a .cs file and
# require a refusal — a guard that never fails is indistinguishable from none.
cp "$GITHUB_WORKSPACE/src/OrderApp/Program.cs" "$GRAPH/Program.cs"
check_not "source guard REFUSES a planted .cs" guard sentinelai-bundle
rm -f "$GRAPH/Program.cs"

# .js specifically, because it was the extension the denylist forgot: ts, tsx and
# jsx were all blocked and js was not, so a whole Node application walked through
# a guard whose entire purpose is stopping exactly that. One planted file per
# language family is cheap; one missing extension is the promise broken.
printf 'module.exports = () => "application source";\n' >"$GRAPH/app.js"
check_not "source guard REFUSES a planted .js" guard sentinelai-bundle
rm -f "$GRAPH/app.js"

printf 'SELECT * FROM customers;\n' >"$GRAPH/dump.sql"
check_not "source guard REFUSES a planted .sql" guard sentinelai-bundle
rm -f "$GRAPH/dump.sql"

echo
echo "== packaging =="
check "bundle packages"           package_bundle
check "tarball exists"            test -f "$BUNDLE.tar.gz"

# Positive controls first. `check_not ... tarball_has` alone was VACUOUS: tar
# exits non-zero on an archive that does not exist, grep never runs, and
# check_not reports a pass — so "no .cs inside the tarball" was at its most
# confident exactly when there was no tarball. These two fail in that case, which
# is what makes the negative below worth reading.
check "tarball is readable"           tarball_readable "$BUNDLE.tar.gz"
check "tarball lists metadata.json"   tarball_has "$BUNDLE.tar.gz" 'metadata\.json$'

check_not "no .cs inside the tarball" tarball_has "$BUNDLE.tar.gz" '\.cs$'

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
