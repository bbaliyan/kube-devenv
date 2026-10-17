#!/usr/bin/env bash
# Run the version command of every tool in the image and fail if any is
# missing or broken. The tool list is tools.txt, one "name|command" per line.
# No `set -e`: check every tool so the failure lists them all.
set -uo pipefail

tools_file="${TOOLS_FILE:-$(dirname "$0")/tools.txt}"

failed=()
while IFS='|' read -r name command; do
  [ -z "$name" ] && continue
  if ! bash -c "$command" >/dev/null 2>&1; then
    failed+=("$name")
  fi
done <"$tools_file"

if [ "${#failed[@]}" -gt 0 ]; then
  echo "smoke: tools missing or broken: ${failed[*]}"
  exit 1
fi
echo "smoke: all tools run"
