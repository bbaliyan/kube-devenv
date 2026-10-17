#!/usr/bin/env bash
# Fail when a commit between <base-ref> and HEAD carries an AI-attribution
# trailer or lacks a Signed-off-by line (set REQUIRE_SIGNOFF=0 for repos
# without a DCO). Skips when there is no real base commit.
set -euo pipefail

base="${1:-}"

if [ -z "$base" ] || [[ "$base" =~ ^0+$ ]]; then
  echo "commit-messages: skip, no base commit (new branch push). The pull request run covers these commits."
  exit 0
fi

if ! git rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
  echo "commit-messages: base '$base' is not a commit here. Fetch full history (fetch-depth 0)."
  exit 1
fi

status=0
for sha in $(git rev-list --no-merges "$base..HEAD"); do
  message="$(git log -1 --format=%B "$sha")"
  short="$(git rev-parse --short "$sha")"
  if [ "${REQUIRE_SIGNOFF:-1}" = "1" ] && ! grep -qi '^Signed-off-by: ' <<<"$message"; then
    echo "$short: missing Signed-off-by"
    status=1
  fi
  if grep -qiE '^(Co-Authored-By:|.*Generated with)' <<<"$message"; then
    echo "$short: AI-attribution line in the commit message"
    status=1
  fi
done

exit "$status"
