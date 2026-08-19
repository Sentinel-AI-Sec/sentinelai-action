#!/usr/bin/env bash
# Shared helpers for the SentinelAI composite action scripts.
# Sourced, never executed directly.

say()  { printf '[sentinelai] %s\n' "$*"; }
warn() { printf '::warning::[sentinelai] %s\n' "$*"; }
fail() { printf '::error::[sentinelai] %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# Scanners degrade gracefully: a missing or broken tool costs us its findings,
# never the whole run. Only bundle-shape violations are fatal.
skip() { warn "$1 not available — skipping (bundle will be missing its findings)"; }

# Write "name=value" to the step output file when running inside Actions.
set_output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  else
    say "output $1=$2"
  fi
}

# Minimal JSON string escaping for the values we emit (paths, ids, versions).
json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

# Resolve a path relative to the workspace, defaulting to the current directory.
workspace_path() {
  local p=${1:-.}
  if [[ "$p" = /* ]]; then
    printf '%s' "$p"
  else
    printf '%s/%s' "${GITHUB_WORKSPACE:-$PWD}" "$p"
  fi
}
