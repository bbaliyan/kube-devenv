#!/usr/bin/env bash
# Behaviour tests for the kube-* verb-scripts in scripts/. Each case runs the real
# script in a temporary workspace, with stub terragrunt, tofu, aws and fzf programs
# first on PATH. The stubs record their arguments in $LOG and print fixed output,
# so no cloud access is needed. Needs bash, git, jq and find.
# No `set -e`: every case runs and failures are counted at the end.
set -uo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

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

export LOG="$work/log"
mkdir -p "$work/bin"
cat >"$work/bin/terragrunt" <<'STUB'
#!/usr/bin/env bash
echo "terragrunt $*" >>"$LOG"
if [[ "${1:-}" == output && "${2:-}" == -json ]]; then
  cat .outputs.json 2>/dev/null || echo '{}'
fi
STUB
for tool in tofu aws; do
  cat >"$work/bin/$tool" <<STUB
#!/usr/bin/env bash
echo "$tool \$*" >>"\$LOG"
STUB
done
cat >"$work/bin/fzf" <<'STUB'
#!/usr/bin/env bash
input="$(cat)"
echo "fzf" >>"$LOG"
if [[ -n "${FZF_PICK:-}" ]]; then echo "$FZF_PICK"; else head -n1 <<<"$input"; fi
STUB
chmod +x "$work/bin/"*
export PATH="$repo/scripts:$work/bin:$PATH"

# new_ws <name> — an empty workspace with live/ and a git repo, so WORKSPACE_FOLDER and
# the repo root agree. Echoes the path.
new_ws() {
  local ws="$work/$1"
  rm -rf "$ws"
  mkdir -p "$ws/live"
  git -C "$ws" init -q
  echo "$ws"
}

unit() { # <ws> <relative dir> [outputs json]
  mkdir -p "$1/$2"
  : >"$1/$2/terragrunt.hcl"
  [[ -n "${3:-}" ]] && echo "$3" >"$1/$2/.outputs.json"
  return 0
}

# run <ws> <dir below ws> <stdin> <command...> — sets OUT (stdout and stderr) and RC,
# and leaves the stub calls in $LOG.
run() {
  local ws="$1" dir="$2" input="$3"
  shift 3
  : >"$LOG"
  OUT="$(cd "$ws/$dir" && printf '%s\n' "$input" | WORKSPACE_FOLDER="$ws" "$@" 2>&1)"
  RC=$?
}

# check <name> <want rc: 0|nonzero> <pattern in OUT> [pattern in LOG] [pattern LOG must lack]
check() {
  local name="$1" want="$2" out_pat="$3" log_pat="${4:-}" log_absent="${5:-}"
  local good=1
  if [[ "$want" == 0 && $RC -ne 0 ]] || [[ "$want" == nonzero && $RC -eq 0 ]]; then good=0; fi
  [[ -n "$out_pat" ]] && ! grep -qE -- "$out_pat" <<<"$OUT" && good=0
  [[ -n "$log_pat" ]] && ! grep -qE -- "$log_pat" "$LOG" && good=0
  [[ -n "$log_absent" ]] && grep -qE -- "$log_absent" "$LOG" && good=0
  if [[ $good -eq 1 ]]; then
    ok "$name"
  else
    bad "$name (rc=$RC, wanted $want)"
    sed 's/^/     out: /' <<<"$OUT"
    sed 's/^/     log: /' "$LOG"
  fi
}

# ---- kube-tf: the tool follows the files -------------------------------------

ws=$(new_ws tf)
unit "$ws" live/proxmox/single
unit "$ws" live/proxmox/ci/control-plane
unit "$ws" live/proxmox/ci/general
mkdir -p "$ws/live/proxmox/stacky" && : >"$ws/live/proxmox/stacky/terragrunt.stack.hcl"
mkdir -p "$ws/live/aws/plain" && : >"$ws/live/aws/plain/main.tf"
mkdir -p "$ws/live/aws/empty"

run "$ws" live/proxmox/single "" kube-tf plan
check "kube-tf plan in a unit runs terragrunt plan" 0 "" '^terragrunt plan$'

run "$ws" live/proxmox/single "" kube-tf init
check "kube-tf init in a unit bootstraps the backend" 0 "" '^terragrunt init --backend-bootstrap$'

run "$ws" live/proxmox/stacky "" kube-tf plan
check "kube-tf plan in a folder with a stack file runs stack run" 0 "" '^terragrunt stack run plan --backend-bootstrap --non-interactive$'

run "$ws" live/proxmox/ci "" kube-tf plan
check "kube-tf plan in a folder of units runs run --all" 0 "" '^terragrunt run --all -- plan$'

run "$ws" live/aws/plain "" kube-tf plan
check "kube-tf plan in a plain OpenTofu root runs tofu" 0 "" '^tofu plan$' '^terragrunt'

run "$ws" live/aws/empty "" kube-tf plan
check "kube-tf in an empty folder fails with a clear error and runs nothing" nonzero "has no terragrunt.hcl" "" '.'

run "$ws" live/proxmox/single "" kube-tf frobnicate
check "kube-tf refuses an unknown verb" nonzero "Usage: kube-tf"

# ---- kube-tf: apply and destroy ask for the path below live/ ---------------

run "$ws" live/proxmox/ci "wrong" kube-tf apply
check "a wrong confirmation word aborts before any tool runs" nonzero "Confirmation did not match" "" '^terragrunt'

run "$ws" live/proxmox/ci "proxmox/ci" kube-tf apply
check "apply over several units lists them with a count, then runs run --all" 0 "ALL 2 units" '^terragrunt run --all --non-interactive --backend-bootstrap -- apply -auto-approve$'
grep -q 'control-plane' <<<"$OUT" && grep -q 'general' <<<"$OUT" && ok "the unit list names each unit" || bad "the unit list names each unit"

run "$ws" live/proxmox/stacky "proxmox/stacky" kube-tf destroy
check "destroy of a stack file names the folder and shows no count" 0 "ALL units of the stack file" '^terragrunt stack run destroy --backend-bootstrap --non-interactive$'
! grep -qE 'ALL [0-9]+ units' <<<"$OUT" && ok "a stack file shows no unit count" || bad "a stack file shows no unit count"

run "$ws" live/aws/plain "aws/plain" kube-tf apply
check "apply in a plain OpenTofu root runs tofu apply -auto-approve" 0 "" '^tofu apply -auto-approve$'

run "$ws" live/proxmox/single "proxmox/single" kube-tf apply
check "apply in a unit runs terragrunt apply -auto-approve" 0 "" '^terragrunt apply --backend-bootstrap -auto-approve$'

# ---- select-folder ------------------------------------------------------------

ws=$(new_ws pick)
unit "$ws" live/proxmox/ci/control-plane
unit "$ws" live/proxmox/ci/general
unit "$ws" live/proxmox/lone
mkdir -p "$ws/live/proxmox/stacky/.terragrunt-stack/gen" && : >"$ws/live/proxmox/stacky/terragrunt.stack.hcl" && : >"$ws/live/proxmox/stacky/.terragrunt-stack/gen/terragrunt.hcl"
mkdir -p "$ws/live/aws/plain" && : >"$ws/live/aws/plain/main.tf"
mkdir -p "$ws/live/proxmox/lone/.terragrunt-cache/x" && : >"$ws/live/proxmox/lone/.terragrunt-cache/x/terragrunt.hcl"
mkdir -p "$ws/modules/m" && : >"$ws/modules/m/main.tf"

run "$ws" "" "" select-folder --list
check "the picker lists a folder of units and a unit inside it, with no clusters/ folder" 0 "" ""
for want in live/proxmox/ci live/proxmox/ci/control-plane live/proxmox/lone live/proxmox/stacky live/aws/plain live/proxmox; do
  grep -qx "$want" <<<"$OUT" && ok "the picker lists $want" || bad "the picker lists $want"
done
for absent in terragrunt-stack terragrunt-cache modules; do
  ! grep -q "$absent" <<<"$OUT" && ok "the picker skips $absent" || bad "the picker skips $absent"
done
[[ ! -s "$LOG" ]] && ok "the picker never calls terragrunt" || bad "the picker never calls terragrunt"

run "$ws" "" "" select-folder live/proxmox/ci
check "select-folder takes a path and prints its label" 0 "Selected: proxmox/ci" ""
[[ "$(cat "$ws/.vscode/.selected-folder")" == "$ws/live/proxmox/ci" ]] && ok "the selection is saved to .selected-folder" || bad "the selection is saved to .selected-folder"
grep -q 'proxmox/ci' "$ws/.vscode/settings.json" && ok "the window title names the folder" || bad "the window title names the folder"

mkdir -p "$ws/live/empty"
run "$ws" "" "" select-folder live/empty
check "select-folder refuses a folder with nothing to apply" nonzero "has no terragrunt.hcl"

run "$ws" "" "" select-folder live/proxmox/lone
FZF_PICK="live/aws/plain" run "$ws" "" "" select-folder
check "the interactive picker saves the chosen folder" 0 "Selected: aws/plain"

# ---- kube-run and the saved selection ---------------------------------------

ws=$(new_ws sel)
unit "$ws" live/aws/eu/dev
run "$ws" "" "" kube-run kube-tf plan
check "kube-run without a selection says to run Select Folder" nonzero "Select Folder"

mkdir -p "$ws/.vscode" && echo "$ws/live/gone" >"$ws/.vscode/.selected-folder"
run "$ws" "" "" kube-run kube-tf plan
check "kube-run with a stale selection says to run Select Folder" nonzero "no longer exists"

# ---- kube-cloud-login: the provider is the folder below live/ ------------------

run "$ws" "" "" select-folder live/aws/eu/dev
run "$ws" "" "" kube-cloud-login
check "login in live/aws runs aws sso login" 0 "" '^aws sso login$'

mkdir -p "$work/outside/u" && : >"$work/outside/u/terragrunt.hcl"
mkdir -p "$ws/.vscode" && echo "$work/outside/u" >"$ws/.vscode/.selected-folder"
run "$ws" "" "" kube-cloud-login
check "login outside live/ fails and names the rule" nonzero "not under live/" "" '.'

# ---- verb kinds ------------------------------------------------------------

win='{"node_provider":{"value":"aws"},"aws_region":{"value":"eu-west-1"},"extra_node_refs":{"value":{"win-dev":{"instance_id":"i-win","ip":"10.0.0.9","provider":"aws"}}}}'
cluster='{"node_provider":{"value":"aws"},"aws_region":{"value":"eu-west-1"},"node_control_ref":{"value":"i-cp"},"cluster_ip":{"value":"10.0.0.1"},"control_plane_node_refs":{"value":{"cp-0":{"instance_id":"i-cp","ip":"10.0.0.1","provider":"aws"}}}}'

ws=$(new_ws kinds)
unit "$ws" live/aws/eu/win "$win"
unit "$ws" live/aws/eu/cluster "$cluster"

select_in() { # <unit dir> — save the selection
  mkdir -p "$ws/.vscode"
  echo "$ws/$1" >"$ws/.vscode/.selected-folder"
}

select_in live/aws/eu/win
run "$ws" "" "" kube-run kube-start
check "Start works on a unit that lists only a Windows machine" 0 "" '^aws ec2 start-instances --instance-ids i-win '

run "$ws" "" "" kube-run kube-kubeconfig
check "Kubeconfig refuses a unit with no control plane in one line" nonzero "^Error: 'aws/eu/win' is not a cluster: it has no control-plane node\.$" "" '^aws'

run "$ws" "" "" kube-run kube-status
check "Status refuses a unit with no Kubernetes nodes in one line" nonzero "^Error: 'aws/eu/win' is not a cluster: it lists no Kubernetes nodes\.$"

run "$ws" "" "" kube-run kube-secrets
check "Secrets refuses a unit with no control plane" nonzero "is not a cluster"

mkdir -p "$ws/live/aws/plain" && : >"$ws/live/aws/plain/main.tf"
select_in live/aws/plain
run "$ws" "" "" kube-run kube-start
check "a machine verb on a plain OpenTofu folder refuses in one line" nonzero "holds no unit" "" '^aws'

mkdir -p "$ws/live/aws/nothing"
unit "$ws" live/aws/blank '{}'
select_in live/aws/blank
run "$ws" "" "" kube-run kube-start
check "a unit with empty outputs lists no machines" nonzero "lists no machines"

# ---- one unit at a time in a folder of units ------------------------------

win2='{"node_provider":{"value":"aws"},"aws_region":{"value":"us-east-1"},"extra_node_refs":{"value":{"win-two":{"instance_id":"i-two","ip":"10.0.1.9","provider":"aws"}}}}'
ws=$(new_ws many)
unit "$ws" live/aws/env/eu "$win"
unit "$ws" live/aws/env/us "$win2"
select_in() { mkdir -p "$ws/.vscode" && echo "$ws/$1" >"$ws/.vscode/.selected-folder"; }
select_in live/aws/env

FZF_PICK="us" run "$ws" "" "" kube-run kube-start
check "a folder of units gets a unit picker, and the verb acts on the chosen unit" 0 "" '^aws ec2 start-instances --instance-ids i-two '
! grep -q 'i-win' "$LOG" && ok "the other unit is left alone" || bad "the other unit is left alone"
[[ "$(grep -c 'terragrunt output -json' "$LOG")" -eq 1 ]] && ok "the verb reads one unit's outputs once" || bad "the verb reads one unit's outputs once"

FZF_PICK="all" run "$ws" "" "" kube-run kube-start
check "Start offers all units and starts every machine in them" 0 "" '^aws ec2 start-instances --instance-ids i-win '
grep -q 'i-two' "$LOG" && ok "all units includes the second unit" || bad "all units includes the second unit"

FZF_PICK="eu" run "$ws" "" "" kube-run kube-kubeconfig
check "a wrong-kind unit chosen from the picker is refused after one read" nonzero "^Error: 'aws/env/eu' is not a cluster" "" '^aws'

# ---- kube-tasks-merge: sets ---------------------------------------------------

ws=$(new_ws tasks)
export KUBE_DEVENV_TASKS_DIR="$repo/tasks"
run "$ws" "" "" kube-tasks-merge --sets core
labels="$(jq -r '.tasks[].label' "$ws/.vscode/tasks.json")"
check "kube-tasks-merge --sets core succeeds" 0 "" ""
for want in "Select Folder" "Cloud Login" "Init" "Plan" "Apply" "Destroy"; do
  grep -q "$want" <<<"$labels" && ok "core has $want" || bad "core has $want"
done
for absent in "Kubeconfig" "Start Node" "Shell" "Tail"; do
  ! grep -q "$absent" <<<"$labels" && ok "core leaves out $absent" || bad "core leaves out $absent"
done

run "$ws" "" "" kube-tasks-merge
labels="$(jq -r '.tasks[].label' "$ws/.vscode/tasks.json")"
for want in "Select Folder" "Plan" "Start Node" "Shell" "Stop Node" "Kubeconfig" "Secrets" "Tail" "Status" "Patch OS"; do
  grep -q "$want" <<<"$labels" && ok "no argument gives $want" || bad "no argument gives $want"
done

run "$ws" "" "" kube-tasks-merge --sets core,machines
labels="$(jq -r '.tasks[].label' "$ws/.vscode/tasks.json")"
grep -q "Shell" <<<"$labels" && ! grep -q "Kubeconfig" <<<"$labels" && ok "core,machines has the machine buttons and no cluster buttons" || bad "core,machines has the machine buttons and no cluster buttons"

run "$ws" "" "" kube-tasks-merge --sets core,bogus
check "an unknown set is refused" nonzero "unknown set 'bogus'"

grep -q 'select-folder' "$repo/tasks/core.json" && ! grep -rq 'select-cluster\|kube-init\|kube-apply' "$repo/tasks" && ok "the task files use the new names" || bad "the task files use the new names"

echo
echo "verbs: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
