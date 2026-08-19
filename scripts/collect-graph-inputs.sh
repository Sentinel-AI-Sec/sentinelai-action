#!/usr/bin/env bash
# Collect the artifacts the backend needs to rebuild the resource graph.
#
# Findings decorate nodes; they carry no edges. Edges come from these files:
#
#   terraform graph DOT   -> the infra spine
#   *.tf                  -> spine fallback + role->resource edges (IAM policies)
#   Dockerfile            -> the code->infra image-name join
#   *.csproj, lock files  -> the dep->code seam
#
# This is a whitelist, not a filter: only these patterns are ever copied, so
# application source cannot reach the bundle by accident. Relative paths are
# preserved so two Dockerfiles in different services don't collide.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCAN_DIR=$(workspace_path "${SCAN_DIR:-.}")
BUNDLE_DIR=$(workspace_path "${BUNDLE_DIR:-sentinelai-bundle}")
INFRA_DIR="$SCAN_DIR/${INFRA_DIR:-infra}"
GRAPH="$BUNDLE_DIR/graph-inputs"

mkdir -p "$GRAPH"

# --- Terraform spine ---------------------------------------------------------
if [[ -d "$INFRA_DIR" ]]; then
  if have terraform; then
    say "terraform: init + graph in $INFRA_DIR"
    # Without init, `terraform graph` prints a thin or empty graph — the single
    # most common way to end up with no infra spine at all.
    if (cd "$INFRA_DIR" && terraform init -backend=false -input=false -no-color >/dev/null); then
      if (cd "$INFRA_DIR" && terraform graph -no-color) >"$GRAPH/terraform-graph.dot"; then
        say "wrote terraform-graph.dot ($(wc -l <"$GRAPH/terraform-graph.dot") lines)"
      else
        warn "terraform graph failed"
        rm -f "$GRAPH/terraform-graph.dot"
      fi
    else
      warn "terraform init failed — no infra spine in this bundle"
    fi
  else
    skip terraform
  fi
else
  warn "no infra dir at $INFRA_DIR — no Terraform artifacts in this bundle"
fi

# --- Whitelisted graph-input files -------------------------------------------
copied=0
copy_matches() {
  local pattern=$1
  local src rel dest
  while IFS= read -r -d '' src; do
    rel=${src#"$SCAN_DIR"/}
    dest="$GRAPH/$rel"
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    copied=$((copied + 1))
    say "collected $rel"
  done < <(find "$SCAN_DIR" \
             \( "${PRUNE_ARGS[@]}" \) -prune -o \
             -type f -name "$pattern" -print0)
}

# Directories never worth walking, plus whatever the caller excluded.
#
# EXCLUDE_DIRS exists because a repository can legitimately hold trees that are
# not the software being scanned - vendored benchmark corpora, sample apps,
# vulnerable-by-design fixtures. Collecting those is not merely noisy: an npm
# package-lock.json swept up from one of them reaches NuGetLockFileParser on the
# backend and fails the whole graph stage, because the two lockfile formats share
# almost a filename and nothing else.
PRUNE_ARGS=( -path "*/.git" -o -path "*/node_modules" -o -path "*/.terraform"
             -o -path "$BUNDLE_DIR" -o -path "*/bin" -o -path "*/obj" )

IFS="," read -ra _excludes <<< "${EXCLUDE_DIRS:-}"
for _d in "${_excludes[@]}"; do
  _d="${_d#/}"; _d="${_d%/}"; _d="${_d# }"; _d="${_d% }"
  [[ -n "$_d" ]] || continue
  PRUNE_ARGS+=( -o -path "$SCAN_DIR/$_d" -o -path "*/$_d" )
  say "excluding $_d from graph inputs"
done

copy_matches '*.tf'
copy_matches '*.tf.json'
copy_matches 'Dockerfile'
copy_matches 'Dockerfile.*'
copy_matches '*.csproj'
copy_matches 'packages.lock.json'
copy_matches 'package-lock.json'

say "collected $copied graph-input file(s) into $GRAPH"

if [[ ! -f "$GRAPH/terraform-graph.dot" && $copied -eq 0 ]]; then
  warn "bundle has no graph inputs — the backend will not be able to build edges"
fi
