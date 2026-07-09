#!/usr/bin/env bash
# dump-versions.sh — print a markdown table of every bundled tool's raw
# version output. Run *inside* the built image (piped in via stdin, not
# executed on the host) so it reports the versions actually installed,
# not just what the Dockerfile's ARGs intended.
set -euo pipefail

row() {
  local tool="$1"
  shift
  printf '| %s | `%s` |\n' "${tool}" "$("$@" 2>&1 | head -1 | tr -d '\r')"
}

# row_grep <tool> <pattern> <cmd...> — like row(), but greps for the first
# matching line instead of assuming the version is on line 1. cosign prints
# ASCII art before its GitVersion line, so head -1 grabs banner art there.
row_grep() {
  local tool="$1" pattern="$2"
  shift 2
  printf '| %s | `%s` |\n' "${tool}" "$("$@" 2>&1 | grep -m1 -E "${pattern}" | tr -d '\r' | sed 's/^ *//')"
}

echo "| Tool | Version |"
echo "|---|---|"
row "tofu" tofu version
row "terragrunt" terragrunt --version
row "kubectl" kubectl version --client
row "helm" helm version
row "aws" aws --version
row "az" az --version
row "sops" sops --version
row "age" age --version
row "gitleaks" gitleaks version
row "trivy" trivy --version
row_grep "cosign" "^GitVersion:" cosign version
row "yamlfmt" yamlfmt --version
row "shfmt" shfmt --version
row "fzf" fzf --version
row "session-manager-plugin" session-manager-plugin --version
