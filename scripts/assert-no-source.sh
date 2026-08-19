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
#
# `js` was missing while `ts`, `tsx` and `jsx` were all present, so an entire
# Node application passed this guard untouched — the one extension a JavaScript
# project is guaranteed to have was the one not listed. `mjs`/`cjs` are the same
# language under different module systems, and `sql`/`sh`/`ps1`/`bat` are added
# because a stored procedure or a deploy script is exactly the kind of thing a
# customer would be alarmed to find had left their runner, whatever a compiler
# would call it.
#
# A denylist can only ever be as complete as the last person to think about it,
# which is why it is the *backstop*: collect-graph-inputs.sh is an allowlist and
# is what actually decides what gets copied. This catches the case where that
# allowlist is changed carelessly.
BLOCKED_EXT='cs|vb|fs|fsx|fsi|cshtml|razor|aspx|asax|ascx|java|kt|kts|py|pyw|pyi|rb|php|go|rs'
BLOCKED_EXT="$BLOCKED_EXT"'|js|mjs|cjs|ts|tsx|jsx|c|cc|cpp|h|hpp|m|mm|swift|scala|groovy|clj'
BLOCKED_EXT="$BLOCKED_EXT"'|sql|sh|bash|ps1|bat|cmd'

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
