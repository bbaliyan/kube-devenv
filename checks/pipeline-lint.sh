#!/usr/bin/env bash
# Fail when a CI wrapper file runs a check itself. Wrapper files may only call
# make targets; every check lives in the Makefile. Files listed in
# .pipelinelintignore (one path per line) are skipped.
set -euo pipefail

root="${1:-.}"
cd "$root"

check_tools='(tofu|terraform) +(fmt|validate|test|plan)|shellcheck|bash +-n|helm +(lint|template|unittest)|kubeconform|yamllint|gitleaks|trivy|promtool|ansible-lint|packer +(fmt|validate)|hadolint|ct +lint'

ignored() {
  [ -f .pipelinelintignore ] && grep -qxF "$1" .pipelinelintignore
}

status=0
while IFS= read -r file; do
  file="${file#./}"
  ignored "$file" && continue
  hits="$(grep -nE "$check_tools" "$file" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  if [ -n "$hits" ]; then
    echo "$file runs a check; move it into a make target:"
    echo "$hits" | sed 's/^/  /'
    status=1
  fi
done < <(
  {
    find .github/workflows -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null || true
    find . -maxdepth 1 -type f -name '.gitlab-ci.yml' 2>/dev/null || true
    find .gitlab -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null || true
  } | sort -u
)

exit "$status"
