#!/usr/bin/env bash
# Create, then edit in place, the single SentinelAI comment on a pull request.
#
# Called twice per run (SEC-43):
#   COMMENT_MODE=ack    — right after the upload, so the PR shows a scan started
#   COMMENT_MODE=final  — once the scan finished, failed, or timed out
#
# ---- One comment, never a thread ------------------------------------------------
# The body carries a hidden HTML marker. Before writing, the existing comments are
# searched for it: found means PATCH that comment, not found means POST a new one.
# So the "final" pass edits the same comment the "ack" pass created, and a re-run on
# the same PR replaces the previous result rather than stacking another comment
# under it. Both invocations go through one code path, which is what keeps the
# "exactly one comment" promise true even if the ack pass was skipped or failed.
#
# ---- Report formatting is SEC-41 ------------------------------------------------
# How findings are rendered is SEC-41's job, not this ticket's. If SEC-41's
# formatter is present it is called; if not, a clearly marked placeholder is shown.
# Nothing here tries to format findings itself. See render_findings below.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COMMENT_MODE=${COMMENT_MODE:?COMMENT_MODE must be 'ack' or 'final'}
GITHUB_TOKEN=${GITHUB_TOKEN:-}
API=${GITHUB_API_URL:-https://api.github.com}
REPO=${GITHUB_REPOSITORY:-}
MARKER='<!-- sentinelai-scan-comment -->'
COMMENT_MAX_TIME=${COMMENT_MAX_TIME:-30}

SCAN_JOB_ID=${SCAN_JOB_ID:-}
UPLOAD_OUTCOME=${UPLOAD_OUTCOME:-}
SCAN_OUTCOME=${SCAN_OUTCOME:-}
SCAN_STAGE=${SCAN_STAGE:-}
ERROR_MESSAGE=${ERROR_MESSAGE:-}
POLL_ENABLED=${POLL_ENABLED:-true}

have jq || fail "jq is required to talk to the GitHub API — install it on this runner"

# Commenting is a courtesy, not the job: a missing token or a non-PR trigger should
# never turn a green scan red. Every early return here is a warning, not a failure.
if [[ -z "$GITHUB_TOKEN" ]]; then
  warn "no github-token available — skipping the PR comment"
  exit 0
fi
if [[ -z "$REPO" ]]; then
  warn "GITHUB_REPOSITORY is not set — skipping the PR comment"
  exit 0
fi

# Works for pull_request/pull_request_target (.pull_request.number) and for
# issue_comment-style events on a PR (.issue.number).
pr_number=""
if [[ -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH}" ]]; then
  pr_number=$(jq -r '.pull_request.number // .issue.number // empty' "$GITHUB_EVENT_PATH" 2>/dev/null || true)
fi
if [[ -z "$pr_number" && "${GITHUB_REF:-}" =~ ^refs/pull/([0-9]+)/ ]]; then
  pr_number="${BASH_REMATCH[1]}"
fi
if [[ -z "$pr_number" ]]; then
  say "not running on a pull request — nothing to comment on"
  exit 0
fi

gh_api() {
  local method=$1 url=$2 data=${3:-}
  local args=(-sS -X "$method" "$url"
    -H "Authorization: Bearer $GITHUB_TOKEN"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
    --max-time "$COMMENT_MAX_TIME")
  if [[ -n "$data" ]]; then
    args+=(-H "Content-Type: application/json" --data "$data")
  fi
  curl "${args[@]}"
}

# ---- Body -----------------------------------------------------------------------

commit_short=${GITHUB_SHA:0:7}
run_url=""
if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
  run_url="${GITHUB_SERVER_URL}/${REPO}/actions/runs/${GITHUB_RUN_ID}"
fi

# SEC-41 owns this. When its formatter lands as scripts/format-report.sh it is
# called here and its markdown is used verbatim; until then the placeholder below
# makes the gap visible on the PR rather than silently showing nothing.
# The backticks below are markdown code formatting, not command substitution.
# shellcheck disable=SC2016
render_findings() {
  local formatter
  formatter="$(dirname "${BASH_SOURCE[0]}")/format-report.sh"
  if [[ -f "$formatter" ]]; then
    SCAN_JOB_ID="$SCAN_JOB_ID" bash "$formatter" 2>/dev/null && return 0
    warn "SEC-41's formatter failed — falling back to the placeholder"
  fi
  printf '> _Findings rendering is SEC-41 and is not wired up yet. '
  printf 'The scan finished successfully; its results are on the backend under scan job `%s`._\n' "$SCAN_JOB_ID"
}

# As above: the backticks are markdown, not command substitution.
# shellcheck disable=SC2016
build_body() {
  printf '%s\n' "$MARKER"

  case "$COMMENT_MODE" in
    ack)
      printf '### 🛡️ SentinelAI security scan started\n\n'
      printf 'Scanning `%s`. This comment will be updated with the result.\n\n' "$commit_short"
      ;;
    final)
      case "$SCAN_OUTCOME" in
        completed)
          printf '### ✅ SentinelAI security scan complete\n\n'
          render_findings
          printf '\n'
          ;;
        failed)
          printf '### ❌ SentinelAI security scan failed\n\n'
          printf '%s\n\n' "${ERROR_MESSAGE:-The scan failed. See the workflow run for details.}"
          ;;
        timeout)
          printf '### ⏱️ SentinelAI security scan timed out\n\n'
          printf '%s\n\n' "${ERROR_MESSAGE:-The scan did not finish in time.}"
          printf 'The scan may still be running on the backend — this only means the '
          printf 'workflow stopped waiting for it.\n\n'
          ;;
        error)
          printf '### ⚠️ SentinelAI could not check the scan\n\n'
          printf '%s\n\n' "${ERROR_MESSAGE:-The backend could not be reached.}"
          ;;
        *)
          # No scan outcome at all. Three different things can cause that, and saying
          # the wrong one is worse than saying nothing — a successful upload reported
          # as "the bundle could not be uploaded" would send someone after the wrong
          # bug entirely.
          if [[ "$UPLOAD_OUTCOME" != "ok" ]]; then
            printf '### ⚠️ SentinelAI scan did not run\n\n'
            printf '%s\n\n' "${ERROR_MESSAGE:-The bundle could not be uploaded to the backend.}"
          elif [[ "$POLL_ENABLED" != "true" ]]; then
            printf '### 🛡️ SentinelAI scan submitted\n\n'
            printf 'The bundle was accepted. This workflow is not configured to wait for '
            printf 'the result, so the scan is still running on the backend.\n\n'
          else
            printf '### ⚠️ SentinelAI could not determine the scan result\n\n'
            printf 'The bundle was uploaded successfully, but the workflow stopped before '
            printf 'it learned how the scan ended. The scan itself may still be running.\n\n'
            if [[ -n "$ERROR_MESSAGE" ]]; then
              printf '%s\n\n' "$ERROR_MESSAGE"
            fi
          fi
          ;;
      esac
      ;;
  esac

  printf '| | |\n|---|---|\n'
  printf '| Commit | `%s` |\n' "$commit_short"
  if [[ -n "$SCAN_JOB_ID" ]]; then
    printf '| Scan job | `%s` |\n' "$SCAN_JOB_ID"
  fi
  if [[ "$COMMENT_MODE" == "final" && -n "$SCAN_STAGE" && "$SCAN_STAGE" != "unknown" ]]; then
    printf '| Last stage | `%s` |\n' "$SCAN_STAGE"
  fi
  if [[ -n "$run_url" ]]; then
    printf '| Workflow run | [logs](%s) |\n' "$run_url"
  fi
}

body=$(build_body)

# ---- Find the existing comment, then edit it or create it -----------------------

find_existing() {
  local page=1 resp ids count
  while (( page <= 10 )); do
    resp=$(gh_api GET "${API}/repos/${REPO}/issues/${pr_number}/comments?per_page=100&page=${page}" 2>/dev/null || true)

    ids=$(printf '%s' "$resp" \
      | jq -r --arg m "$MARKER" '.[]? | select(.body != null and (.body | contains($m))) | .id' 2>/dev/null || true)
    if [[ -n "$ids" ]]; then
      printf '%s' "$(printf '%s\n' "$ids" | head -n1)"
      return 0
    fi

    # A short page means there are no more comments to look through.
    count=$(printf '%s' "$resp" | jq -r 'length // 0' 2>/dev/null || printf '0')
    if [[ "$count" -lt 100 ]]; then break; fi
    page=$(( page + 1 ))
  done
  printf ''
}

payload=$(jq -n --arg body "$body" '{body: $body}')
existing=$(find_existing)

if [[ -n "$existing" ]]; then
  if gh_api PATCH "${API}/repos/${REPO}/issues/comments/${existing}" "$payload" >/dev/null; then
    say "updated PR comment $existing on #$pr_number"
    set_output "comment-id" "$existing"
  else
    warn "could not update PR comment $existing"
  fi
else
  new_id=$(gh_api POST "${API}/repos/${REPO}/issues/${pr_number}/comments" "$payload" \
    | jq -r '.id // empty' 2>/dev/null || true)
  if [[ -n "$new_id" ]]; then
    say "created PR comment $new_id on #$pr_number"
    set_output "comment-id" "$new_id"
  else
    warn "could not create a PR comment — check that the workflow grants 'pull-requests: write'"
  fi
fi
