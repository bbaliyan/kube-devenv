#!/usr/bin/env bash
# Lint and render every Helm chart under a repo, then validate the rendered
# manifests with kubeconform against the Kubernetes schemas and a CRD catalog.
# Plain manifest directories listed in MANIFEST_DIRS (space separated) are
# validated the same way. A repo with no chart and no manifest dir passes.
set -euo pipefail

root="${1:-.}"
cd "$root"

crd_catalog='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
schema_args=(-strict -summary -schema-location default -schema-location "${CRD_SCHEMA_LOCATION:-$crd_catalog}")
[ "${KUBECONFORM_IGNORE_MISSING_SCHEMAS:-0}" = "1" ] && schema_args+=(-ignore-missing-schemas)

status=0

while IFS= read -r chart_file; do
  chart="$(dirname "$chart_file")"
  echo "== chart $chart =="
  if grep -q '^dependencies:' "$chart_file"; then
    helm dependency build "$chart" >/dev/null || status=1
  fi
  helm lint "$chart" || status=1

  value_sets=("")
  for values in "$chart"/ci/*values.yaml; do
    [ -f "$values" ] && value_sets+=("--values $values")
  done
  for set in "${value_sets[@]}"; do
    # shellcheck disable=SC2086
    helm template "$chart" $set | kubeconform "${schema_args[@]}" || status=1
  done
done < <(find . -name Chart.yaml -not -path '*/charts/*/charts/*' -not -path './.git/*' | sort)

for dir in ${MANIFEST_DIRS:-}; do
  echo "== manifests $dir =="
  kubeconform "${schema_args[@]}" "$dir" || status=1
done

exit "$status"
