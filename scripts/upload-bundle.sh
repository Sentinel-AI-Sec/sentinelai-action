#!/usr/bin/env bash
# POST the bundle to the backend: multipart, metadata part + tarball part.
#
# Expected reply is 202 Accepted with a scan job id and a poll URL (SEC-13);
# scanning is asynchronous, so nothing here waits for a result. Polling and PR
# annotation are SEC-41.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BACKEND_URL=${BACKEND_URL:?backend-url is required}
MACHINE_TOKEN=${MACHINE_TOKEN:?machine-token is required}
AUTH_SCHEME=${AUTH_SCHEME:-Bearer}
BUNDLE_DIR=$(workspace_path "${BUNDLE_DIR:-sentinelai-bundle}")
BUNDLE_PATH=${BUNDLE_PATH:-${BUNDLE_DIR}.tar.gz}
FAIL_ON_UPLOAD_ERROR=${FAIL_ON_UPLOAD_ERROR:-true}

[[ -f "$BUNDLE_PATH" ]] || fail "no packaged bundle at $BUNDLE_PATH"
[[ -f "$BUNDLE_DIR/metadata.json" ]] || fail "no metadata at $BUNDLE_DIR/metadata.json"

endpoint="${BACKEND_URL%/}/v1/scans"
body=${RUNNER_TEMP:-/tmp}/sentinelai-response.json

say "uploading $(wc -c <"$BUNDLE_PATH" | tr -d ' ') bytes to $endpoint"

# The token goes in via a header file so it never appears in a process listing.
hdr=$(mktemp)
trap 'rm -f "$hdr"' EXIT
printf 'Authorization: %s %s\n' "$AUTH_SCHEME" "$MACHINE_TOKEN" >"$hdr"
chmod 600 "$hdr"

code=$(curl -sS -X POST "$endpoint" \
  -H @"$hdr" \
  -H "Accept: application/json" \
  -F "metadata=@$BUNDLE_DIR/metadata.json;type=application/json" \
  -F "bundle=@$BUNDLE_PATH;type=application/gzip" \
  --max-time 300 \
  --retry 3 --retry-delay 5 --retry-connrefused \
  -o "$body" -w '%{http_code}') || code="000"

say "backend responded $code"
if [[ -s "$body" ]]; then sed 's/^/  /' "$body"; fi

if [[ "$code" != 2* ]]; then
  if [[ "$FAIL_ON_UPLOAD_ERROR" == "true" ]]; then
    fail "upload failed with HTTP $code"
  fi
  warn "upload failed with HTTP $code (fail-on-upload-error is false, continuing)"
  set_output "scan-job-id" ""
  set_output "poll-url" ""
  exit 0
fi

# Small, dependency-free field extraction — jq is not guaranteed on every runner.
extract() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$body" | head -n1; }

job_id=$(extract scan_job_id)
poll_url=$(extract poll_url)

set_output "scan-job-id" "$job_id"
set_output "poll-url" "$poll_url"

say "scan job ${job_id:-unknown} accepted; poll at ${poll_url:-unknown}"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    printf '### SentinelAI scan submitted\n\n'
    printf '| | |\n|---|---|\n'
    printf '| Scan job | `%s` |\n' "${job_id:-unknown}"
    printf '| Commit | `%s` |\n' "${GITHUB_SHA:-unknown}"
    printf '| Poll URL | `%s` |\n' "${poll_url:-unknown}"
  } >>"$GITHUB_STEP_SUMMARY"
fi
