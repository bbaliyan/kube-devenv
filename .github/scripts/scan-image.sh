#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Scan a published image for fixable CRITICAL and HIGH vulnerabilities and keep
# one open issue in sync with the result. Findings open or update the issue;
# a clean scan closes it. Never blocks a release.
# Needs: trivy, jq, gh (with GH_TOKEN and GH_REPO set).
# Usage: scan-image.sh [image]   (default ghcr.io/$GITHUB_REPOSITORY_OWNER/kube-devenv:latest)
set -euo pipefail

image="${1:-ghcr.io/${GITHUB_REPOSITORY_OWNER:?set GITHUB_REPOSITORY_OWNER or pass an image}/kube-devenv:latest}"
ignore_file="${TRIVY_IGNORE_FILE:-.trivyignore}"
label="image-vulnerabilities"
title="Image vulnerability scan: findings in ${image%%:*}"
max_rows=50

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

trivy image --quiet \
  --severity CRITICAL,HIGH --ignore-unfixed \
  --ignorefile "$ignore_file" \
  --format json --output "$work/report.json" "$image"

findings="$(jq '[.Results[]?.Vulnerabilities[]?] | unique_by(.VulnerabilityID + .PkgName + .InstalledVersion)' "$work/report.json")"
count="$(jq 'length' <<<"$findings")"
open_issue="$(gh issue list --label "$label" --state open --json number --jq '.[0].number // empty')"

if [ "$count" -eq 0 ]; then
  echo "scan: no findings in $image"
  if [ -n "$open_issue" ]; then
    gh issue close "$open_issue" --comment "The latest scan of \`$image\` found nothing. Closing."
  fi
  exit 0
fi

run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
{
  echo "The scheduled scan of \`$image\` found $count fixable CRITICAL or HIGH finding(s)."
  echo
  echo "Scanned: $(date -u +%F). Run: $run_url"
  echo
  echo "| Severity | ID | Package | Installed | Fixed in |"
  echo "|---|---|---|---|---|"
  jq -r --argjson max "$max_rows" \
    '.[:$max][] | "| \(.Severity) | \(.VulnerabilityID) | \(.PkgName) | \(.InstalledVersion) | \(.FixedVersion) |"' \
    <<<"$findings"
  if [ "$count" -gt "$max_rows" ]; then
    echo
    echo "Showing $max_rows of $count. The run log has the rest."
  fi
  echo
  echo "To accept a finding for a while, add it to \`.trivyignore\` with an \`exp:\` date."
  echo "This issue updates on every scan and closes when the scan is clean."
} >"$work/body.md"

if [ -n "$open_issue" ]; then
  gh issue edit "$open_issue" --title "$title" --body-file "$work/body.md"
  echo "scan: updated issue #$open_issue"
else
  gh label create "$label" --color B60205 --description "Open findings from the scheduled image scan" 2>/dev/null || true
  gh issue create --title "$title" --label "$label" --body-file "$work/body.md"
fi
