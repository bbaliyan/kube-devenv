#!/usr/bin/env bash
# Fail when a rendered Argo CD Application or AppProject has neither the resources
# finalizer nor a complete opt-out. Without the finalizer, a deleted or pruned
# Application leaves what it deployed running, unowned.
# An opt-out is the annotation kube-stack/keep-resources-on-delete with a reason,
# plus Prune=false and Delete=false in argocd.argoproj.io/sync-options, and no
# resources finalizer.
# Argo CD also deletes the resources of an Application for the /foreground and
# /background forms of the finalizer, so they count as the finalizer there. An
# AppProject takes only the plain form.
#
# Usage: argocd-removal.sh <rendered file or directory>...
# Pass rendered manifests, not Helm templates; - reads standard input. No
# argument may be empty, and together they must hold an Application or an
# AppProject.
#
# The rule is a JSON Schema in argocd-removal/, and kubeconform applies it. Why a
# script: kubeconform passes when it matched nothing, so a wrong path or an empty
# render would pass.
set -euo pipefail

[ "$#" -gt 0 ] || { echo "usage: argocd-removal.sh <rendered file or directory>..." >&2; exit 2; }

schemas="$(cd "$(dirname "$0")" && pwd)/argocd-removal"

failed=0
found=0
for input in "$@"; do
  status=0
  # The path has the API group, so an Application kind of another group is skipped.
  out="$(kubeconform -strict -summary -ignore-missing-schemas \
    -schema-location "$schemas/{{ if eq .Group \"argoproj.io\" }}{{ .ResourceKind }}{{ else }}none{{ end }}.json" "$input" 2>&1)" || status=$?
  echo "$out"

  if grep -q ' Errors: [1-9]' <<<"$out"; then
    echo "argocd-removal: could not read $input"
    failed=1
  fi
  if grep -q ' Invalid: [1-9]' <<<"$out"; then
    echo "argocd-removal: add the finalizer resources-finalizer.argocd.argoproj.io, or opt out (see $0)"
    failed=1
  elif [ "$status" -ne 0 ]; then
    failed=1
  elif grep -q '^Summary: 0 resource' <<<"$out"; then
    echo "argocd-removal: nothing to check in $input"
    failed=1
  fi
  if grep -q ' Valid: [1-9]' <<<"$out"; then found=1; fi
done
if [ "$failed" -eq 0 ] && [ "$found" -eq 0 ]; then
  echo "argocd-removal: no Application or AppProject found in $*"
  failed=1
fi
exit "$failed"
