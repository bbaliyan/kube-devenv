#!/usr/bin/env bash
# Fail when a rendered Argo CD Application or AppProject has neither the resources
# finalizer nor a complete opt-out. Without the finalizer, a deleted or pruned
# Application leaves what it deployed running, unowned.
# An opt-out is the annotation kube-stack/keep-resources-on-delete with a reason,
# plus Prune=false and Delete=false in argocd.argoproj.io/sync-options, and no
# resources finalizer.
#
# Usage: argocd-removal.sh <rendered file or directory>...
# Pass rendered manifests, not Helm templates.
#
# The rule is a JSON Schema in argocd-removal/, and kubeconform applies it. Why a
# script: kubeconform passes when it matched nothing, so a wrong path or an empty
# render would pass.
set -euo pipefail

[ "$#" -gt 0 ] || { echo "usage: argocd-removal.sh <rendered file or directory>..." >&2; exit 2; }

schemas="$(cd "$(dirname "$0")" && pwd)/argocd-removal"

status=0
# The path has the API group, so an Application kind of another group is skipped.
out="$(kubeconform -strict -summary -ignore-missing-schemas \
  -schema-location "$schemas/{{ if eq .Group \"argoproj.io\" }}{{ .ResourceKind }}{{ else }}none{{ end }}.json" "$@" 2>&1)" || status=$?
echo "$out"

if [ "$status" -ne 0 ]; then
  echo "argocd-removal: add the finalizer resources-finalizer.argocd.argoproj.io, or opt out (see $0)"
  exit 1
fi
if grep -q ' Valid: 0,' <<<"$out"; then
  echo "argocd-removal: no Application or AppProject found in $*"
  exit 1
fi
