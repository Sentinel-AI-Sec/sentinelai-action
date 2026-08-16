#!/usr/bin/env bash
# POST the bundle to the backend: multipart, metadata part + tarball part.
#
# Expected reply is 202 Accepted carrying a scan job id and a poll URL (SEC-13);
# scanning is asynchronous, so nothing here waits for a result. SEC-43's poll step
# does the waiting, using the scan-job-id this script sets.
#
# ---- Wire format (SEC-43) -------------------------------------------------------
# The deployed backend wraps every reply in a shared Response envelope and
# serializes with .NET's defaults, so what actually arrives is:
#
#   { "statusCode": 202, "isSuccess": true, "message": "scan job accepted",
#     "data": { "scanJobId": "...", "pollUrl": "/v1/scans/...", "status": 0 } }
#
# camelCase, nested under .data. API_DOC_V1.md documents a flat snake_case shape
# (scan_job_id, poll_url) that the server does not send — this script previously
# read those names and silently extracted nothing, reporting success with an empty
# job id. Every read below accepts either spelling, so this keeps working if the
# backend is later brought in line with the document.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BACKEND_URL=${BACKEND_URL:?backend-url is required}
MACHINE_TOKEN=${MACHINE_TOKEN:?machine-token is required}
AUTH_SCHEME=${AUTH_SCHEME:-Bearer}
BUNDLE_DIR=$(workspace_path "${BUNDLE_DIR:-sentinelai-bundle}")
BUNDLE_PATH=${BUNDLE_PATH:-${BUNDLE_DIR}.tar.gz}
FAIL_ON_UPLOAD_ERROR=${FAIL_ON_UPLOAD_ERROR:-true}
UPLOAD_MAX_TIME=${UPLOAD_MAX_TIME:-300}

# jq replaced a hand-rolled sed extractor here: the envelope above is nested, and
# matching nested JSON with a regex is how the empty-job-id bug happened. jq ships
# on every GitHub-hosted runner; a self-hosted runner without it gets told so
# plainly rather than failing later with an unexplained empty id.
have jq || fail "jq is required to read the backend's response — install it on this runner"

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
  --max-time "$UPLOAD_MAX_TIME" \
  --retry 3 --retry-delay 5 --retry-connrefused \
  -o "$body" -w '%{http_code}') || code="000"

say "backend responded $code"
if [[ -s "$body" ]]; then sed 's/^/  /' "$body"; fi

# Read one field, tolerating a body that is empty or not JSON at all — a 401 from
# the JWT middleware has no body, and a proxy error page is not JSON.
json() { jq -r "${1} // empty" "$body" 2>/dev/null || true; }

backend_msg=$(json '.message')

# Every exit path sets these before returning, so the comment step always has
# something to say (SEC-43: never a silent hang, never a raw stack trace).
record() {
  set_output "scan-job-id" "${1:-}"
  set_output "poll-url" "${2:-}"
  set_output "upload-outcome" "$3"
  set_output "error-message" "${4:-}"
}

if [[ "$code" != 2* ]]; then
  # Prefer the backend's own wording when it sent any: it knows what went wrong
  # (e.g. "metadata.project_id is missing or not a GUID - set the action's
  # 'project-id' input"), and it is better than anything guessed from a status code.
  case "$code" in
    000) reason="could not reach the backend at $endpoint — network error, DNS failure, or no response within ${UPLOAD_MAX_TIME}s" ;;
    401) reason="authentication failed — the machine token is invalid or expired${backend_msg:+ ($backend_msg)}" ;;
    403) reason="${backend_msg:-the machine token is missing the 'scan:write' scope}" ;;
    404) reason="${backend_msg:-no such project for this tenant — check the 'project-id' input}" ;;
    413) reason="the bundle is larger than the backend accepts (64 MB limit)" ;;
    422) reason="${backend_msg:-the backend rejected the bundle contents}" ;;
    429) reason="rate limited by the backend — try again later" ;;
    5*)  reason="the backend returned a server error (HTTP $code)${backend_msg:+: $backend_msg}" ;;
    *)   reason="${backend_msg:-upload failed with HTTP $code}" ;;
  esac

  record "" "" "failed" "$reason"

  if [[ "$FAIL_ON_UPLOAD_ERROR" == "true" ]]; then
    fail "$reason"
  fi
  warn "$reason (fail-on-upload-error is false, continuing)"
  exit 0
fi

job_id=$(json '.data.scanJobId // .scan_job_id')
poll_url=$(json '.data.pollUrl // .poll_url')

# A 2xx with no job id is not a success we can build on — the poll step would have
# nothing to poll. Previously this passed silently and printed "scan job unknown".
if [[ -z "$job_id" ]]; then
  reason="the backend returned HTTP $code but no scan job id — the response was not in a shape this action understands"
  record "" "" "failed" "$reason"
  if [[ "$FAIL_ON_UPLOAD_ERROR" == "true" ]]; then
    fail "$reason"
  fi
  warn "$reason (fail-on-upload-error is false, continuing)"
  exit 0
fi

# The backend hands back a root-relative poll URL ("/v1/scans/{id}"). Resolve it
# against the configured base so the poll step can curl it directly, and fall back
# to composing it ourselves if the field was absent.
case "$poll_url" in
  "")      poll_url="${BACKEND_URL%/}/v1/scans/${job_id}" ;;
  http*)   : ;;
  /*)      poll_url="${BACKEND_URL%/}${poll_url}" ;;
  *)       poll_url="${BACKEND_URL%/}/${poll_url}" ;;
esac

record "$job_id" "$poll_url" "ok" ""

say "scan job $job_id accepted; poll at $poll_url"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  # The backticks below are markdown code formatting, not command substitution.
  # shellcheck disable=SC2016
  {
    printf '### SentinelAI scan submitted\n\n'
    printf '| | |\n|---|---|\n'
    printf '| Scan job | `%s` |\n' "$job_id"
    printf '| Commit | `%s` |\n' "${GITHUB_SHA:-unknown}"
    printf '| Poll URL | `%s` |\n' "$poll_url"
  } >>"$GITHUB_STEP_SUMMARY"
fi
