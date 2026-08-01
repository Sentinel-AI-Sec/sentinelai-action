#!/usr/bin/env bash
# Package the assembled bundle directory into the tarball we upload.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BUNDLE_DIR=$(workspace_path "${BUNDLE_DIR:-sentinelai-bundle}")
BUNDLE_PATH="${BUNDLE_DIR}.tar.gz"

[[ -d "$BUNDLE_DIR" ]] || fail "no bundle at $BUNDLE_DIR"
[[ -f "$BUNDLE_DIR/metadata.json" ]] || fail "bundle has no metadata.json"

tar -czf "$BUNDLE_PATH" -C "$BUNDLE_DIR" .

# Re-run the guard against the packed tarball: the directory being clean a moment
# ago is not proof that what we are about to send is.
TARGET="$BUNDLE_PATH" bash "$(dirname "${BASH_SOURCE[0]}")/assert-no-source.sh"

sha=$(sha256sum "$BUNDLE_PATH" | cut -d' ' -f1)
size=$(wc -c <"$BUNDLE_PATH" | tr -d ' ')

set_output "bundle-path" "$BUNDLE_PATH"
set_output "bundle-sha256" "$sha"

say "packaged $BUNDLE_PATH ($size bytes, sha256 $sha)"
tar -tzf "$BUNDLE_PATH" | sed 's/^/  /'
