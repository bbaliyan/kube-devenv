#!/usr/bin/env bash
# Contract tests for the tools in the image. smoke.sh proves that a tool starts. This
# file proves that a tool still does the one job a repo of ours relies on, offline and
# with local state, so a version bump that changes its behaviour fails the PR that
# makes it. It does not test upstream behaviour beyond that job, and it needs no cloud
# account. Tools that need a network or a credential (aws, az, gh, trivy, cosign) stay
# at the smoke test.
# Run inside the built image. A tool that is missing is a failure, not a skip.
# No `set -e`: every case runs and failures are counted at the end.
set -uo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HOME="$work/home" TG_DOWNLOAD_DIR="$work/tg-download" TF_IN_AUTOMATION=1 CHECKPOINT_DISABLE=1
mkdir -p "$HOME"

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  echo "ok   $1"
}
bad() {
  fail=$((fail + 1))
  echo "FAIL $1"
}

# job <name> <want rc: 0|nonzero> <command...>: runs the command; shows its output on failure
job() {
  local name="$1" want="$2" out rc
  shift 2
  out="$("$@" 2>&1)"
  rc=$?
  if { [[ "$want" == 0 && $rc -eq 0 ]] || [[ "$want" == nonzero && $rc -ne 0 ]]; }; then
    ok "$name"
  else
    bad "$name (rc=$rc, wanted $want)"
    sed 's/^/     /' <<<"$out" | tail -15
  fi
}

# ---- tofu and terragrunt, through kube-tf ----------------------------------

lab="$work/lab"
mkdir -p "$lab/modules/demo" "$lab/units/demo" "$lab/live/aws/unit" "$lab/live/aws/env/a" "$lab/live/aws/env/b" \
  "$lab/live/aws/stack" "$lab/live/aws/plain"
cat >"$lab/modules/demo/main.tf" <<'TF'
variable "region" {
  default = "x"
}
resource "terraform_data" "r" {
  input = var.region
}
TF
cp "$lab/modules/demo/main.tf" "$lab/live/aws/plain/main.tf"
cat >"$lab/units/demo/terragrunt.hcl" <<HCL
terraform {
  source = "$lab/modules/demo"
}
inputs = {
  region = values.region
}
HCL
for d in unit env/a env/b; do
  cat >"$lab/live/aws/$d/terragrunt.hcl" <<HCL
terraform {
  source = "$lab/modules/demo"
}
inputs = {
  region = "a"
}
HCL
done
cat >"$lab/live/aws/stack/terragrunt.stack.hcl" <<HCL
unit "use1" {
  source = "$lab/units/demo"
  path   = "use1"
  values = {
    region = "us-east-1"
  }
}
unit "euw1" {
  source = "$lab/units/demo"
  path   = "euw1"
  values = {
    region = "eu-west-1"
  }
}
HCL
git -C "$lab" init -q

kube_tf() { # <folder below live/> <verb> — the confirmation word is the folder path
  (cd "$lab/live/$1" && printf '%s\n' "$1" | WORKSPACE_FOLDER="$lab" PATH="$repo/scripts:$PATH" kube-tf "$2")
}
for folder in aws/unit aws/env aws/stack aws/plain; do
  for verb in init plan apply destroy; do
    job "kube-tf $verb works on $folder with the real tools" 0 kube_tf "$folder" "$verb"
  done
done
job "the picker lists the folder of units and skips generated units" 0 bash -c "
  cd '$lab' && out=\$(WORKSPACE_FOLDER='$lab' PATH='$repo/scripts:$PATH' select-folder --list) &&
  grep -qx live/aws/env <<<\"\$out\" && ! grep -q terragrunt-stack <<<\"\$out\""

# ---- sops and age: the round trip that Terragrunt's sops_decrypt_file relies on -----

age-keygen -o "$work/age.key" >/dev/null 2>&1
printf 'token: s3cret\n' >"$work/secret.yaml"
job "sops encrypts with an age key and decrypts back to the same value" 0 bash -c "
  cd '$work' && recipient=\$(age-keygen -y age.key) &&
  sops --config /dev/null --encrypt --age \"\$recipient\" secret.yaml >secret.enc.yaml &&
  ! grep -q s3cret secret.enc.yaml &&
  [ \"\$(SOPS_AGE_KEY_FILE=age.key sops --decrypt secret.enc.yaml)\" = 'token: s3cret' ]"

# ---- lint and format tools: a bad input must fail, a good input must pass ----------

printf 'a: 1\nb:\n  - x\n' >"$work/good.yaml"
printf 'a: 1\n  b: [\n' >"$work/bad.yaml"
job "yamllint passes good YAML" 0 yamllint -d relaxed "$work/good.yaml"
job "yamllint fails broken YAML" nonzero yamllint -d relaxed "$work/bad.yaml"

printf '#!/usr/bin/env bash\necho "$1"\n' >"$work/good.sh"
printf '#!/usr/bin/env bash\necho $1 $(ls $2)\n' >"$work/bad.sh"
job "shellcheck passes a quoted script" 0 shellcheck -S warning "$work/good.sh"
job "shellcheck fails an unquoted script" nonzero shellcheck -S warning "$work/bad.sh"
printf '#!/usr/bin/env bash\nif true; then\necho hi\nfi\n' >"$work/unformatted.sh"
job "shfmt finds an unformatted script" nonzero shfmt -d "$work/unformatted.sh"
job "shfmt passes a formatted script" 0 shfmt -d "$work/good.sh"

printf 'FROM alpine:latest\nRUN echo hi\n' >"$work/Dockerfile.bad"
printf 'FROM alpine:3.20\nRUN echo hi\n' >"$work/Dockerfile.good"
job "hadolint passes a pinned base image" 0 hadolint --failure-threshold warning "$work/Dockerfile.good"
job "hadolint fails an unpinned base image" nonzero hadolint --failure-threshold warning "$work/Dockerfile.bad"

# ---- Prometheus rules and Kubernetes manifests -------------------------------------

cat >"$work/rules-good.yml" <<'YAML'
groups:
  - name: demo
    rules:
      - alert: Down
        expr: up == 0
        for: 5m
YAML
printf 'groups:\n  - name: demo\n    rules:\n      - alert: Down\n        expr: up ==\n' >"$work/rules-bad.yml"
job "promtool passes a valid rule file" 0 promtool check rules "$work/rules-good.yml"
job "promtool fails an invalid expression" nonzero promtool check rules "$work/rules-bad.yml"

printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\ndata:\n  k: v\n' >"$work/cm-good.yaml"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\ndata: 7\n' >"$work/cm-bad.yaml"
job "kubeconform passes a valid manifest" 0 kubeconform -strict "$work/cm-good.yaml"
job "kubeconform fails an invalid manifest" nonzero kubeconform -strict "$work/cm-bad.yaml"

# ---- helm and helm-unittest ---------------------------------------------------------

mkdir -p "$work/chart/templates" "$work/chart/tests"
printf 'apiVersion: v2\nname: demo\nversion: 0.1.0\n' >"$work/chart/Chart.yaml"
printf 'name: world\n' >"$work/chart/values.yaml"
cat >"$work/chart/templates/cm.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: demo
data:
  greeting: {{ .Values.name | quote }}
YAML
cat >"$work/chart/tests/cm_test.yaml" <<'YAML'
suite: demo
templates:
  - cm.yaml
tests:
  - it: renders the name
    set:
      name: abc
    asserts:
      - equal:
          path: data.greeting
          value: abc
YAML
job "helm template renders a chart" 0 bash -c "helm template demo '$work/chart' | grep -q 'greeting: \"world\"'"
job "helm unittest passes a chart test" 0 helm unittest "$work/chart"
sed -i 's/value: abc/value: nope/' "$work/chart/tests/cm_test.yaml"
job "helm unittest fails a wrong assertion" nonzero helm unittest "$work/chart"

# ---- Ansible and Packer: the files our image and node repos use ----------------------

cat >"$work/play.yml" <<'YAML'
---
- name: Demo
  hosts: localhost
  gather_facts: false
  tasks:
    - name: Say hello
      ansible.builtin.debug:
        msg: hello
YAML
job "ansible-playbook accepts a valid playbook" 0 ansible-playbook --syntax-check "$work/play.yml"
job "ansible-playbook runs a local playbook" 0 ansible-playbook -i localhost, -c local "$work/play.yml"
printf -- '---\n- hosts: localhost\n  tasks:\n    - ansible.builtin.nonexistent_module:\n        x: 1\n' >"$work/play-bad.yml"
job "ansible-playbook fails an unknown module" nonzero ansible-playbook --syntax-check "$work/play-bad.yml"

cat >"$work/demo.pkr.hcl" <<'HCL'
source "null" "demo" {
  communicator = "none"
}
build {
  sources = ["source.null.demo"]
}
HCL
job "packer validates a template" 0 packer validate "$work/demo.pkr.hcl"
printf 'source "null" "demo" {\n  nonsense = true\n}\nbuild {\n  sources = ["source.null.demo"]\n}\n' >"$work/bad.pkr.hcl"
job "packer fails an invalid template" nonzero packer validate "$work/bad.pkr.hcl"

# ---- kubectl: reads a kubeconfig without a cluster ------------------------------------

cat >"$work/kubeconfig" <<'YAML'
apiVersion: v1
kind: Config
clusters:
  - name: demo
    cluster:
      server: https://127.0.0.1:6443
contexts:
  - name: demo
    context:
      cluster: demo
      user: u
current-context: demo
users:
  - name: u
    user:
      token: x
YAML
job "kubectl reads a kubeconfig" 0 bash -c "kubectl --kubeconfig '$work/kubeconfig' config current-context | grep -qx demo"

echo
echo "tools: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
