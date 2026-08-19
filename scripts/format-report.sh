#!/usr/bin/env bash
# SEC-41 — render the backend's draft audit as the body of the PR comment.
#
# pr-comment.sh calls this and uses whatever reaches stdout verbatim. Any non-zero
# exit falls back to its placeholder, so every failure mode here is "say nothing
# and let the caller explain" rather than "post something misleading".
#
# Two API calls, because a report cannot be reached in one:
#
#   GET /v1/scans/{id}     -> reportId
#   GET /v1/reports/{id}   -> the audit
#
# The first hop exists because POST /v1/scans/{id}/audit is the only other place a
# report id is returned, and nothing calls it now that SEC-46's worker drives the
# pipeline. Older backends do not carry reportId on the scan; against those this
# exits 1 and the placeholder stands.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCAN_JOB_ID=${SCAN_JOB_ID:-}
BACKEND_URL=${BACKEND_URL:-}
MACHINE_TOKEN=${MACHINE_TOKEN:-}
AUTH_SCHEME=${AUTH_SCHEME:-Bearer}
FETCH_MAX_TIME=${FETCH_MAX_TIME:-30}

[[ -n "$SCAN_JOB_ID" && -n "$BACKEND_URL" && -n "$MACHINE_TOKEN" ]] || exit 1
have jq || exit 1

base="${BACKEND_URL%/}"

# Header file rather than -H on the command line: the token would otherwise show up
# in a process listing, same reason upload-bundle.sh does it.
hdr=$(mktemp)
trap 'rm -f "$hdr" "${scan_body:-}" "${report_body:-}"' EXIT
printf 'Authorization: %s %s\n' "$AUTH_SCHEME" "$MACHINE_TOKEN" >"$hdr"
chmod 600 "$hdr"

fetch() {
  local url=$1 out=$2 code
  code=$(curl -sS -H @"$hdr" -H "Accept: application/json" \
           --max-time "$FETCH_MAX_TIME" -o "$out" -w '%{http_code}' "$url") || return 1
  [[ "$code" == "200" ]] || return 1
}

scan_body=$(mktemp)
fetch "$base/v1/scans/$SCAN_JOB_ID" "$scan_body" || exit 1

# The scan wraps its payload in `data`; the report does not. Not a typo - the two
# endpoints genuinely differ, so each is read the way it actually answers.
report_id=$(jq -r '(.data.reportId // .data.report_id) // empty' "$scan_body")
[[ -n "$report_id" ]] || exit 1        # audit has not run, or the report was not retained

report_body=$(mktemp)
fetch "$base/v1/reports/$report_id" "$report_body" || exit 1

jq -r '
  def esc: gsub("\\|"; "\\|") | gsub("\n"; " ");

  ([.chains[]? | select(.status == "validated")]) as $validated
  | ([.chains[]? | select(.status != "validated")]) as $candidates
  | (.citations // []) as $cites
  | (.cost // {}) as $cost

  | "**Draft audit** — " +
    (if ($validated | length) > 0
     then ($validated | length | tostring) + " validated chain(s)"
     else "no chain survived validation" end) +
    " of " + ((.chains // []) | length | tostring) + " candidate(s), " +
    ($cites | length | tostring) + " citation(s)."
  , ""
  , "| | |"
  , "|---|---|"
  , "| Validated chains | " + ($validated | length | tostring) + " |"
  , "| Candidates | " + ($candidates | length | tostring) + " |"
  , "| Cited knowledge | " + ($cites | length | tostring) + " |"
  , "| Model calls | " + (($cost.model_calls // 0) | tostring) + " |"
  , "| Corpus | `" + (.corpus_version // "unknown") + "` |"
  , ""

  # Only validated chains get a table. Rendering 47 candidates would bury the one
  # thing the debate actually stood behind, and GitHub truncates long comments.
  , ( $validated[]? |
      "##### Chain `" + (.id[0:8]) + "` — " + (.hop_count | tostring) +
        " hops, min confidence `" + (.min_confidence // "unknown") + "`"
      , ""
      , "| # | node | Blue | edge |"
      , "|---|---|---|---|"
      , ( .hops[]? |
          "| " + ((.order // 0) | tostring) +
          " | `" + ((.node_key // "—") | esc) + "`" +
          " | " + (.blue_verdict // (if .blue_validated then "confirmed" else "unassessed" end)) +
          " | " + ((.edge_confidence // "—") | tostring) + " |" )
      , "" )

  , ( if (.summary // "") != "" then
        ( "<details><summary>Adjudication</summary>", "", "```text", .summary, "```", "</details>", "" )
      else empty end )

  , ( if ($cites | length) > 0 then
        ( "<details><summary>Cited knowledge (" + ($cites | length | tostring) + ")</summary>", ""
        , ( $cites[] | "- `" + (.knowledge_id // "?") + "` — " + (.collection // "?") )
        , "", "</details>", "" )
      else empty end )

  , "_Draft audit. Every claim above is cited; nothing here is an assertion the debate could not ground._"
' "$report_body"
