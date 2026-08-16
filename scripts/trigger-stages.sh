#!/usr/bin/env bash
# TEMPORARY (SEC-46): drive the backend's pipeline stages from the runner.
#
# ---- Why this exists, and what removes it ---------------------------------------
# SEC-46 (Pipeline B orchestration) is the ticket that makes a scan run by itself
# once a bundle lands. Until it ships, the backend has no queue-driven worker: a
# submitted job is written as Queued and nothing ever picks it up. The graph and
# audit stages only run when someone calls POST /v1/scans/{id}/graph and
# POST /v1/scans/{id}/audit by hand — the backend's own comments describe both as
# manually triggered "because no queue-driven worker exists yet".
#
# SEC-43 is simply the first ticket that needs a scan to *finish* rather than just
# be accepted, so it is the first to trip over the gap. Rather than block on an
# unscheduled ticket, this calls those two endpoints itself.
#
# This is the wrong side of the API boundary — a CI runner has no business driving
# a server's internal pipeline — so it is opt-in (trigger-stages, default false)
# and should be deleted, along with its inputs, the moment SEC-46 lands. Leaving it
# on afterwards would re-run stages the worker has already run; neither handler
# guards against a second invocation, so the graph stage would write duplicate
# node and edge rows.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BACKEND_URL=${BACKEND_URL:?backend-url is required}
MACHINE_TOKEN=${MACHINE_TOKEN:?machine-token is required}
AUTH_SCHEME=${AUTH_SCHEME:-Bearer}
SCAN_JOB_ID=${SCAN_JOB_ID:?scan job id is required}

# Separate budgets, because the two stages are nothing alike. The graph stage is
# parsing and graph traversal with no model calls, so it returns in seconds. The
# audit stage runs the retrieval and the agent debate — real model calls — and
# blocks for minutes. Both are deliberately independent of the poll loop's budget:
# these are synchronous requests, not polls.
TRIGGER_GRAPH_MAX_TIME=${TRIGGER_GRAPH_MAX_TIME:-300}
TRIGGER_AUDIT_MAX_TIME=${TRIGGER_AUDIT_MAX_TIME:-900}

have jq || fail "jq is required to read the backend's response — install it on this runner"

body=${RUNNER_TEMP:-/tmp}/sentinelai-trigger.json

hdr=$(mktemp)
trap 'rm -f "$hdr"' EXIT
printf 'Authorization: %s %s\n' "$AUTH_SCHEME" "$MACHINE_TOKEN" >"$hdr"
chmod 600 "$hdr"

json() { jq -r "${1} // empty" "$body" 2>/dev/null || true; }

record() {
  set_output "trigger-outcome" "$1"
  set_output "error-message" "${2:-}"
}

# Returns the HTTP code; "000" when curl itself gave up (including on --max-time).
call_stage() {
  local stage=$1 max_time=$2 code
  code=$(curl -sS -X POST "${BACKEND_URL%/}/v1/scans/${SCAN_JOB_ID}/${stage}" \
    -H @"$hdr" \
    -H "Accept: application/json" \
    -H "Content-Length: 0" \
    --max-time "$max_time" \
    -o "$body" -w '%{http_code}') || code="000"
  printf '%s' "$code"
}

for stage in graph audit; do
  case "$stage" in
    graph) max_time=$TRIGGER_GRAPH_MAX_TIME ;;
    audit) max_time=$TRIGGER_AUDIT_MAX_TIME ;;
  esac

  say "triggering the $stage stage for scan $SCAN_JOB_ID (up to ${max_time}s)"
  code=$(call_stage "$stage" "$max_time")
  backend_msg=$(json '.message')

  case "$code" in
    2*)
      say "$stage stage finished"
      ;;

    # curl gave up waiting, but the server is almost certainly still working — the
    # audit stage routinely outlives a client timeout. Handing over to the poll loop
    # is the right move here; failing would abandon a scan that is about to finish.
    000)
      warn "the $stage stage did not return within ${max_time}s — leaving it running and letting the poll step wait for it"
      record "handed-off" ""
      exit 0
      ;;

    401) msg="authentication failed when starting the $stage stage — the machine token is invalid or expired" ;;
    403) msg="${backend_msg:-the machine token is missing the 'scan:write' scope}" ;;
    404) msg="scan job $SCAN_JOB_ID was not found when starting the $stage stage" ;;
    409) msg="${backend_msg:-the $stage stage cannot run yet for this job}" ;;
    410) msg="this job's bundle has already been purged, so the $stage stage cannot run" ;;
    *)   msg="the $stage stage failed (HTTP $code)${backend_msg:+: $backend_msg}" ;;
  esac

  if [[ "$code" != 2* ]]; then
    record "failed" "$msg"
    fail "$msg"
  fi
done

record "ok" ""
say "both stages ran; the poll step should find this scan already complete"
