#!/usr/bin/env bash
# Poll GET /v1/scans/{id} until the scan reaches a terminal state (SEC-43).
#
# Bounded by a hard wall-clock deadline: this runs on a PR, so hanging until the
# job's own 6-hour limit is not an acceptable failure mode. Every exit path — done,
# failed, timed out, unreachable — records an outcome and a human-readable message
# for the PR comment step.
#
# ---- Reading the status (SEC-43) ------------------------------------------------
# The response is the same Response envelope the upload returns, with .NET's default
# serializer settings, so the fields arrive as:
#
#   { "statusCode": 200, "isSuccess": true,
#     "data": { "status": 1, "stage": 4, "failureReason": null, "completedAt": null } }
#
# Two things follow from that:
#
#   1. `status` and `stage` are enum *ordinals*, not words — 2 is Completed, not
#      "completed" — because no JsonStringEnumConverter is registered. Both forms are
#      accepted below so this survives that being fixed.
#
#   2. `status` alone cannot be trusted to spot a failure. RunAuditStageCommandHandler
#      sets Status = Completed only on the success branch; when the audit stage fails
#      it records FailureReason and leaves Status at Running, so a dead job reports
#      itself as running forever. `failureReason` is therefore checked first, and
#      `completedAt` — written atomically with the Completed status — is preferred
#      over the ordinal. (Flagged to the backend team; the graph stage does set
#      Status = Failed correctly, so this is an inconsistency between the two stages.)
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BACKEND_URL=${BACKEND_URL:?backend-url is required}
MACHINE_TOKEN=${MACHINE_TOKEN:?machine-token is required}
AUTH_SCHEME=${AUTH_SCHEME:-Bearer}
SCAN_JOB_ID=${SCAN_JOB_ID:?scan job id is required}
POLL_URL=${POLL_URL:-"${BACKEND_URL%/}/v1/scans/${SCAN_JOB_ID}"}

# Wall-clock budget for the whole loop, the interval to start at, the ceiling the
# backoff climbs to, and the per-request cap. The per-request cap matters
# independently: without it a connection that opens and then stalls would sit inside
# one curl call and blow the whole budget in a single attempt.
POLL_TIMEOUT=${POLL_TIMEOUT:-900}
POLL_INTERVAL=${POLL_INTERVAL:-10}
POLL_MAX_INTERVAL=${POLL_MAX_INTERVAL:-60}
POLL_MAX_TIME=${POLL_MAX_TIME:-30}

have jq || fail "jq is required to read the backend's response — install it on this runner"

body=${RUNNER_TEMP:-/tmp}/sentinelai-poll.json

hdr=$(mktemp)
trap 'rm -f "$hdr"' EXIT
printf 'Authorization: %s %s\n' "$AUTH_SCHEME" "$MACHINE_TOKEN" >"$hdr"
chmod 600 "$hdr"

json() { jq -r "${1} // empty" "$body" 2>/dev/null || true; }

# Enum ordinals as the backend currently sends them, plus the word forms it would
# send if a JsonStringEnumConverter is ever registered.
status_name() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    0|queued)    printf 'queued' ;;
    1|running)   printf 'running' ;;
    2|completed) printf 'completed' ;;
    3|failed)    printf 'failed' ;;
    *)           printf 'unknown' ;;
  esac
}

stage_name() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    0|received)  printf 'received' ;;
    1|normalize) printf 'normalize' ;;
    2|graph)     printf 'graph' ;;
    3|retrieve)  printf 'retrieve' ;;
    4|debate)    printf 'debate' ;;
    5|report)    printf 'report' ;;
    *)           printf 'unknown' ;;
  esac
}

record() {
  set_output "scan-outcome" "$1"
  set_output "scan-stage" "${2:-unknown}"
  set_output "error-message" "${3:-}"
}

say "polling $POLL_URL (timeout ${POLL_TIMEOUT}s, first check in ${POLL_INTERVAL}s)"

deadline=$(( SECONDS + POLL_TIMEOUT ))
interval=$POLL_INTERVAL
attempt=0
stage="unknown"
last_transient=""

while :; do
  attempt=$(( attempt + 1 ))

  code=$(curl -sS -X GET "$POLL_URL" \
    -H @"$hdr" \
    -H "Accept: application/json" \
    --max-time "$POLL_MAX_TIME" \
    -o "$body" -w '%{http_code}') || code="000"

  case "$code" in
    2*)
      fail_reason=$(json '.data.failureReason // .failure_reason')
      completed_at=$(json '.data.completedAt // .completed_at')
      stage=$(stage_name "$(json '.data.stage // .stage')")
      status=$(status_name "$(json '.data.status // .status')")

      # Order matters — see the header note. failureReason is the only signal that
      # catches an audit-stage failure, which leaves status reading "running".
      if [[ -n "$fail_reason" ]]; then
        record "failed" "$stage" "the scan failed during the $stage stage: $fail_reason"
        fail "scan $SCAN_JOB_ID failed during $stage: $fail_reason"
      fi

      if [[ -n "$completed_at" || "$status" == "completed" ]]; then
        say "scan $SCAN_JOB_ID completed after ${SECONDS}s ($attempt checks)"
        record "completed" "$stage" ""
        break
      fi

      if [[ "$status" == "failed" ]]; then
        record "failed" "$stage" "the scan failed during the $stage stage"
        fail "scan $SCAN_JOB_ID failed during $stage"
      fi

      say "attempt $attempt: status=$status stage=$stage (${SECONDS}s elapsed)"
      last_transient=""
      ;;

    # Retrying will not fix credentials or a missing job, so these end the loop now
    # rather than burning the whole budget to reach the same answer.
    401)
      msg="authentication failed while polling — the machine token is invalid or expired"
      record "error" "$stage" "$msg"; fail "$msg" ;;
    403)
      msg=$(json '.message'); msg=${msg:-"the machine token is missing the 'scan:read' scope"}
      record "error" "$stage" "$msg"; fail "$msg" ;;
    404)
      msg="scan job $SCAN_JOB_ID was not found — it may belong to a different tenant"
      record "error" "$stage" "$msg"; fail "$msg" ;;

    # Everything else is treated as transient: a 5xx, a rate limit, a dropped
    # connection or a stalled request (000). Keep polling until the deadline.
    000) last_transient="the backend did not respond within ${POLL_MAX_TIME}s"
         warn "attempt $attempt: $last_transient — retrying" ;;
    429) last_transient="the backend is rate limiting this token"
         warn "attempt $attempt: $last_transient — retrying" ;;
    *)   last_transient="the backend returned HTTP $code"
         warn "attempt $attempt: $last_transient — retrying" ;;
  esac

  remaining=$(( deadline - SECONDS ))
  if (( remaining <= 0 )); then
    if [[ -n "$last_transient" ]]; then
      msg="gave up after ${POLL_TIMEOUT}s — $last_transient"
    else
      msg="the scan did not finish within ${POLL_TIMEOUT}s (last seen at the $stage stage)"
    fi
    record "timeout" "$stage" "$msg"
    fail "$msg"
  fi

  # Never sleep past the deadline: the last wait should land on it, not overshoot it.
  sleep_for=$interval
  if (( sleep_for > remaining )); then
    sleep_for=$remaining
  fi
  sleep "$sleep_for"

  # Exponential backoff, capped. Starts responsive for the quick scans and backs off
  # so a long audit is not polled hundreds of times.
  interval=$(( interval * 2 ))
  if (( interval > POLL_MAX_INTERVAL )); then
    interval=$POLL_MAX_INTERVAL
  fi
done

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  # The backticks below are markdown code formatting, not command substitution.
  # shellcheck disable=SC2016
  {
    printf '### SentinelAI scan completed\n\n'
    printf '| | |\n|---|---|\n'
    printf '| Scan job | `%s` |\n' "$SCAN_JOB_ID"
    printf '| Duration | %ss over %s checks |\n' "$SECONDS" "$attempt"
  } >>"$GITHUB_STEP_SUMMARY"
fi
