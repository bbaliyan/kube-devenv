#!/usr/bin/env bash
# Contract tests for the tools in the image. smoke.sh proves that a tool starts. This
# file proves that a tool still does the one job a repo of ours relies on, offline and
# with local state, so a version bump that changes its behaviour fails the PR that
# makes it. It does not test upstream behaviour beyond that job, and it needs no cloud
# account. Tools that need a network or a credential (aws, az, gh, trivy) stay
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

# The units, the stack file and the plain root are real files in tests/fixtures/terragrunt/.
# The copy is a git repository because the units find their module with get_repo_root().
lab="$work/lab"
cp -r "$repo/tests/fixtures/terragrunt" "$lab"
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

# ---- kube-tf: a unit that left the stack file ---------------------------------
# Terragrunt never deletes the folder of a unit that was removed from a stack file or
# moved. A stack run would run that folder too. kube-tf must stop before plan, apply and
# init, name the extra folders, and delete nothing. A destroy must go on.

stale="$lab/live/aws/stale"
mkdir -p "$stale" "$lab/stacks/inner"
units_hcl() {
  local n
  for n in "$@"; do
    printf 'unit "%s" {\n  source = "${get_repo_root()}/units/demo"\n  path = "%s"\n  values = {\n    region = "test-region-1"\n  }\n}\n' "$n" "$n"
  done
}
inner_block() { printf 'stack "inner" {\n  source = "${get_repo_root()}/stacks/inner"\n  path = "inner"\n}\n'; }
nodot_unit() {
  printf 'unit "%s" {
  source = "${get_repo_root()}/units/demo"
  path = "%s"
  no_dot_terragrunt_stack = true
  values = {
    region = "test-region-1"
  }
}
' "$1" "$1"
}
top_stack() { units_hcl "$@" >"$stale/terragrunt.stack.hcl"; }
top_stack_with_inner() { { units_hcl "$@"; inner_block; } >"$stale/terragrunt.stack.hcl"; }
inner_stack() { units_hcl "$@" >"$lab/stacks/inner/terragrunt.stack.hcl"; }
generate_now() { (cd "$stale" && terragrunt stack generate >/dev/null 2>&1); }
fresh() { rm -rf "$stale/.terragrunt-stack"; }

# stale_run <verb>: sets OUT (stdout and stderr) and RC
stale_run() {
  OUT="$(cd "$stale" && printf 'aws/stale\n' | WORKSPACE_FOLDER="$lab" PATH="$repo/scripts:$PATH" kube-tf "$1" 2>&1)"
  RC=$?
}
# stale_expect <name> <want rc: 0|nonzero> <pattern in OUT that must match> <pattern that must not>
stale_expect() {
  local good=1
  if [[ "$2" == 0 && $RC -ne 0 ]] || [[ "$2" == nonzero && $RC -eq 0 ]]; then good=0; fi
  [[ -n "$3" ]] && ! grep -qE -- "$3" <<<"$OUT" && good=0
  [[ -n "$4" ]] && grep -qE -- "$4" <<<"$OUT" && good=0
  if [[ $good -eq 1 ]]; then
    ok "$1"
  else
    bad "$1 (rc=$RC)"
    sed 's/^/     /' <<<"$OUT" | tail -15
  fi
}
stack_dir_exists() { [[ -f "$stale/$1/terragrunt.hcl" ]]; }
no_probe_left() { ! compgen -G "$lab/live/aws/.kube-tf-probe.*" >/dev/null; }

fresh
top_stack a b
stale_run plan
stale_expect "stale check: a clean checkout with no generated folder passes" 0 "" "no longer in the stack file"

generate_now
top_stack a b c
stale_run plan
stale_expect "stale check: a unit added to the stack file passes" 0 "" "no longer in the stack file"

fresh
top_stack a b
generate_now
mkdir -p "$stale/.terragrunt-stack/a/.terragrunt-cache/x" "$stale/.terragrunt-stack/a/.terraform/y"
: >"$stale/.terragrunt-stack/a/.terragrunt-cache/x/terragrunt.hcl"
: >"$stale/.terragrunt-stack/a/.terraform/y/terragrunt.hcl"
stale_run plan
stale_expect "stale check: an unchanged stack passes, and cache folders do not count as units" 0 "" "no longer in the stack file"

fresh
top_stack a b c
generate_now
top_stack a b d
stale_run plan
stale_expect "stale check: a removed unit stops plan and is listed" nonzero "^  \.terragrunt-stack/c$" "terragrunt-stack/(a|b|d)$"
stale_expect "stale check: the message gives the steps" nonzero "terragrunt state list" ""
stack_dir_exists .terragrunt-stack/c && ok "stale check: it deletes nothing" || bad "stale check: it deletes nothing"
no_probe_left && ok "stale check: it leaves no scratch folder" || bad "stale check: it leaves no scratch folder"
stale_run init
stale_expect "stale check: init stops too" nonzero "^  \.terragrunt-stack/c$" ""
stale_run apply
stale_expect "stale check: apply stops before it asks for the confirmation" nonzero "^  \.terragrunt-stack/c$" "Type '"
stale_run destroy
stale_expect "stale check: destroy goes on and says it will destroy the extra folder" 0 "Notice: .*terragrunt-stack/c are no longer in the stack file" ""

fresh
top_stack a b c
generate_now
top_stack a
stale_run plan
stale_expect "stale check: with several extra folders, the text lists each and says one clean after all" nonzero "^  \.terragrunt-stack/b$" ""
stale_expect "stale check: the text lists the second extra folder too" nonzero "^  \.terragrunt-stack/c$" ""
stale_expect "stale check: the text says to destroy" nonzero "terragrunt destroy" ""
stale_expect "stale check: the text says to clean from the stack folder" nonzero "terragrunt stack clean. in the stack folder" ""

fresh
{ units_hcl a; nodot_unit n; } >"$stale/terragrunt.stack.hcl"
generate_now
stack_dir_exists n && ok "stale check: a no_dot_terragrunt_stack unit is generated outside .terragrunt-stack" || bad "stale check: a no_dot_terragrunt_stack unit is generated outside .terragrunt-stack"
mkdir -p "$stale/committed"
printf 'terraform {
  source = "${get_repo_root()}/modules/demo"
}
inputs = {
  region = "test-region-1"
}
' >"$stale/committed/terragrunt.hcl"
stale_run plan
stale_expect "stale check: a no_dot unit that is still defined, and a committed unit, pass" 0 "" "no longer in the stack file"
top_stack a
stale_run plan
stale_expect "stale check: a removed no_dot_terragrunt_stack unit is caught" nonzero "^  n$" "committed|terragrunt-stack/a"
rm -rf "$stale/n" "$stale/committed"

TMP_BAD=$(cd "$stale" && printf 'aws/stale
' | TMPDIR=/nonexistent-dir WORKSPACE_FOLDER="$lab" PATH="$repo/scripts:$PATH" kube-tf plan 2>&1)
RC=$?
OUT="$TMP_BAD"
fresh
stale_expect "stale check: a scratch file that cannot be made stops the run before anything is copied or run" nonzero "cannot create a scratch file" "Generating|terragrunt-stack"
[[ ! -e /terragrunt.stack.hcl ]] && ok "stale check: nothing is copied to the root folder" || bad "stale check: nothing is copied to the root folder"

fresh
top_stack a b c
generate_now
top_stack a b c2
stale_run plan
stale_expect "stale check: a unit renamed in the stack file is caught" nonzero "^  \.terragrunt-stack/c$" "c2"

fresh
top_stack a y
generate_now
inner_stack y
top_stack_with_inner a
stale_run plan
stale_expect "stale check: a unit moved from the top level into a nested stack is caught" nonzero "^  \.terragrunt-stack/y$" "inner"

fresh
inner_stack x y
top_stack_with_inner a
generate_now
top_stack a x y
stale_run plan
stale_expect "stale check: units moved out of a nested stack are caught, with the nested stack folder" nonzero "^  \.terragrunt-stack/inner/\.terragrunt-stack/x$" "^  \.terragrunt-stack/(a|x|y)$"

fresh
inner_stack x y
top_stack_with_inner a
generate_now
inner_stack x
stale_run plan
stale_expect "stale check: a nested stack that drops a unit is caught" nonzero "^  \.terragrunt-stack/inner/\.terragrunt-stack/y$" "stack/x$"

fresh
printf 'unit "bad" {\n  source = "${get_repo_root()}/units/missing"\n  path = "bad"\n  values = {}\n}\n' >"$stale/terragrunt.stack.hcl"
stale_run plan
stale_expect "stale check: a stack that cannot be generated shows the real error" nonzero "failed to fetch unit bad" "no longer in the stack file"
stale_expect "stale check: a failed generate says what it could not do" nonzero "cannot generate the stack" ""
no_probe_left && ok "stale check: a failed generate leaves no scratch folder" || bad "stale check: a failed generate leaves no scratch folder"
fresh

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

# ---- tflint and terraform-docs: the module checks of kube-compute ------------------------

mkdir -p "$work/tfmod"
cat >"$work/tfmod/main.tf" <<'HCL'
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

variable "name" {
  type        = string
  description = "Name of the thing."
}

resource "aws_instance" "good" {
  ami           = "ami-0123456789abcdef0"
  instance_type = "t3.micro"
  tags          = { Name = var.name }
}
HCL
printf 'plugin "aws" {
  enabled = true
}
' >"$work/tfmod/.tflint.hcl"
job "tflint passes a module with the baked AWS ruleset" 0 tflint --chdir "$work/tfmod"
sed 's/t3.micro/t3.nonexistent/' "$work/tfmod/main.tf" >"$work/tfmod/bad.tf"
job "tflint fails an invalid instance type" 0 bash -c "tflint --chdir '$work/tfmod' | grep -q aws_instance_invalid_type"
rm "$work/tfmod/bad.tf"

printf '# demo

<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->
' >"$work/tfmod/README.md"
job "terraform-docs fails on a stale table" nonzero terraform-docs markdown table --output-file README.md --output-mode inject --output-check "$work/tfmod"
job "terraform-docs injects the tables" 0 terraform-docs markdown table --output-file README.md --output-mode inject "$work/tfmod"
job "terraform-docs passes on a current table" 0 terraform-docs markdown table --output-file README.md --output-mode inject --output-check "$work/tfmod"

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
