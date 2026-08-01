#!/usr/bin/env bash
# Prove the bundle carries no application source.
#
# "Your code never leaves your runner" is the product's core privacy promise, and
# this is the check that makes it true rather than intended. The collector is
# already a whitelist; this is the backstop that runs anyway, on the directory
# before packaging and on the tarball after. The backend repeats it on ingest
# (SEC-13) — neither side trusts the other to have done it.
#
# Usage: TARGET=<dir-or-tarball> assert-no-source.sh
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TARGET=$(workspace_path "${TARGET:?TARGET must be set}")

# Application source in any language we might plausibly meet. .csproj and
# packages.lock.json are manifests, not source, and stay allowed.
BLOCKED_EXT='cs|vb|fs|cshtml|razor|aspx|java|kt|py|rb|php|go|rs|ts|tsx|jsx|c|cc|cpp|h|hpp|m|swift|scala'

listing=$(mktemp)
trap 'rm -f "$listing" "$listing.hits"' EXIT

if [[ -d "$TARGET" ]]; then
  (cd "$TARGET" && find . -type f) >"$listing"
elif [[ -f "$TARGET" ]]; then
  tar -tzf "$TARGET" >"$listing"
else
  fail "nothing to check at $TARGET"
fi

if grep -aEi "\.(${BLOCKED_EXT})\$" "$listing" >"${listing}.hits"; then
  printf '::error::[sentinelai] application source found in the bundle:\n' >&2
  sed 's/^/  /' "${listing}.hits" >&2
  rm -f "${listing}.hits"
  fail "refusing to upload — the bundle must never contain application source"
fi
rm -f "${listing}.hits"

say "source guard passed on $TARGET ($(grep -c . "$listing") file(s), no application source)"
