#!/usr/bin/env bash
# Scan a repo for secrets and for values that must not be committed: gitleaks
# defaults plus the shared rules in gitleaks.toml. A repo that has its own
# .gitleaks.toml owns the config and extends the shared file for its allowlist.
set -euo pipefail

root="${1:-.}"
shared="$(dirname "$0")/gitleaks.toml"

args=(--no-banner --redact)
[ -f "$root/.gitleaks.toml" ] || args+=(--config "$shared")

if [ -d "$root/.git" ]; then
  gitleaks git "${args[@]}" "$root"
else
  gitleaks dir "${args[@]}" "$root"
fi
