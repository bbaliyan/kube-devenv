#!/usr/bin/env bash
# Lint and render every Helm chart under a repo, then validate the rendered
# manifests with kubeconform against the Kubernetes schemas and a CRD catalog.
# Plain manifest directories listed in MANIFEST_DIRS (space separated) are
# validated the same way. A repo with no chart and no manifest dir passes.
#
# Test values: a chart is rendered with the defaults and with each <chart>/ci/*values.yaml.
# With HELM_VALUES_ROOT=<dir> (relative to the repo), the values of a chart come from
# <dir>/<chart directory name>/*.yaml instead, so the chart directory holds only what ships.
# A chart that has such files is linted and rendered with each of them and not with the
# defaults, because a chart with required values cannot render without them.
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

  if [ -n "${HELM_VALUES_ROOT:-}" ]; then
    candidates=("$HELM_VALUES_ROOT/$(basename "$chart")"/*.yaml)
    cases=()
  else
    candidates=("$chart"/ci/*values.yaml)
    cases=("")
  fi
  for values in "${candidates[@]}"; do [ -f "$values" ] && cases+=("$values"); done
  [ "${#cases[@]}" -gt 0 ] || cases=("")

  for values in "${cases[@]}"; do
    helm lint "$chart" ${values:+--values "$values"} || status=1
    helm template "$chart" ${values:+--values "$values"} | kubeconform "${schema_args[@]}" || status=1
  done
done < <(find . -name Chart.yaml -not -path '*/charts/*/charts/*' -not -path './.git/*' | sort)

for dir in ${MANIFEST_DIRS:-}; do
  echo "== manifests $dir =="
  kubeconform "${schema_args[@]}" "$dir" || status=1
done

exit "$status"
