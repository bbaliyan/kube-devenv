#!/usr/bin/env bash
# Scan a repo for secrets and for values that must not be committed: gitleaks
# defaults plus the shared rules in gitleaks.toml. A repo that has its own
# .gitleaks.toml owns the config and extends the shared file for its allowlist.
#
# Usage: secrets.sh [dir] [base-ref]
# With a base ref, scan only the commits in <base-ref>..HEAD, so a bad commit on
# another branch cannot fail this one. Without one (main, push), scan the full
# history of HEAD. Never scan every ref: a CI checkout fetches all branches.
# A directory with no .git (file or directory) is scanned as plain files.
set -euo pipefail

root="${1:-.}"
base="${2:-}"
shared="$(dirname "$0")/gitleaks.toml"

args=(--no-banner --redact)
[ -f "$root/.gitleaks.toml" ] || args+=(--config "$shared")

if [ ! -e "$root/.git" ]; then
  gitleaks dir "${args[@]}" "$root"
  exit
fi

range=HEAD
if [ -n "$base" ] && ! [[ "$base" =~ ^0+$ ]]; then
  if ! git -C "$root" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    echo "secrets: base '$base' is not a commit here. Fetch full history (fetch-depth 0)."
    exit 1
  fi
  range="$base..HEAD"
fi

gitleaks git "${args[@]}" --log-opts "$range" "$root"
