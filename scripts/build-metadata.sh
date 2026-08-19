#!/usr/bin/env bash
# Write bundle/metadata.json — the JSON part of the multipart upload.
#
# Shape is fixed by the API design (POST /v1/scans, section 5.1). The artifact
# manifest is generated from what is actually in the bundle, never from what we
# hoped would be there, so provenance matches reality when a scanner degraded.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BUNDLE_DIR=$(workspace_path "${BUNDLE_DIR:-sentinelai-bundle}")
PROJECT_ID=${PROJECT_ID:-}
MODEL_TIER_HINT=${MODEL_TIER_HINT:-auto}
RETAIN_REPORT=${RETAIN_REPORT:-false}
RUNNER_SECRET_SCAN=${RUNNER_SECRET_SCAN:-skipped}
COMMIT_SHA=${GITHUB_SHA:-}
PR_REF=${GITHUB_REF:-}

[[ -d "$BUNDLE_DIR" ]] || fail "no bundle at $BUNDLE_DIR"

# kind/tool for each artifact, as the backend's ingest expects them.
classify() {
  local rel=$1 base
  base=$(basename "$rel")
  case "$base" in
    checkov_infra.sarif)    printf 'sarif|checkov' ;;
    checkov_docker.sarif)   printf 'sarif|checkov' ;;
    trivy.sarif)            printf 'sarif|trivy' ;;
    osv.sarif)              printf 'sarif|osv-scanner' ;;
    roslyn.sarif)           printf 'sarif|roslyn-security' ;;
    *.sarif)                printf 'sarif|unknown' ;;
    terraform-graph.dot)    printf 'dot|terraform' ;;
    *.tf|*.tf.json)         printf 'tf|terraform' ;;
    Dockerfile|Dockerfile.*) printf 'dockerfile|docker' ;;
    *.csproj|packages.lock.json) printf 'manifest|nuget' ;;
    package-lock.json)      printf 'manifest|npm' ;;
    scanner-versions.json)  printf 'provenance|sentinelai' ;;
    *)                      printf 'other|unknown' ;;
  esac
}

# Scanner versions are written by run-scanners.sh; inline them so the metadata is
# self-describing even if the file is read separately.
versions_json="{}"
if [[ -f "$BUNDLE_DIR/scanner-versions.json" ]]; then
  versions_json=$(tr -d '\n' <"$BUNDLE_DIR/scanner-versions.json" | sed 's/  */ /g')
fi

artifacts=""
while IFS= read -r rel; do
  rel=${rel#./}
  if [[ "$rel" == "metadata.json" ]]; then continue; fi
  IFS='|' read -r kind tool <<<"$(classify "$rel")"
  if [[ -n "$artifacts" ]]; then
    artifacts+=",
"
  fi
  artifacts+=$(printf '    { "kind": "%s", "tool": "%s", "filename": "%s" }' \
    "$(json_escape "$kind")" "$(json_escape "$tool")" "$(json_escape "$rel")")
done < <(cd "$BUNDLE_DIR" && find . -type f | sort)

case "$RETAIN_REPORT" in true|True|TRUE|1|yes) retain=true ;; *) retain=false ;; esac

cat >"$BUNDLE_DIR/metadata.json" <<EOF
{
  "project_id": "$(json_escape "$PROJECT_ID")",
  "pr_ref": "$(json_escape "$PR_REF")",
  "commit_sha": "$(json_escape "$COMMIT_SHA")",
  "model_tier_hint": "$(json_escape "$MODEL_TIER_HINT")",
  "retain_report": $retain,
  "runner_secret_scan": "$(json_escape "$RUNNER_SECRET_SCAN")",
  "scanner_versions": $versions_json,
  "artifacts": [
$artifacts
  ]
}
EOF

say "wrote metadata.json"
cat "$BUNDLE_DIR/metadata.json"
