#!/usr/bin/env bash
# kube-common.sh — shared helpers for the verb-scripts (kube-tf, kube-status,
# kube-shell, kube-kubeconfig, kube-start, kube-run, kube-cloud-login). Sourced,
# not run directly: `source kube-common.sh` (found via PATH like the other scripts).
#
# The selected folder is any folder under live/. Its kind comes from the files in
# it (target_mode). A verb that acts on machines or a cluster reads one unit's
# outputs once and refuses a unit of the wrong kind. No helper reads a folder
# layout such as clusters/ to find out what a folder is.

# selected_folder_dir — resolve the persisted 'Select Folder' choice to an
# absolute path, or exit with a clear error. Echoes the path on success.
selected_folder_dir() {
  local workspace persist_file dir
  workspace="${WORKSPACE_FOLDER:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  persist_file="${workspace}/.vscode/.selected-folder"

  if [[ ! -f "${persist_file}" ]]; then
    echo "Error: no folder selected — run 'Select Folder' first." >&2
    exit 1
  fi

  dir="$(cat "${persist_file}")"

  if [[ ! -d "${dir}" ]]; then
    echo "Error: selected folder '${dir}' no longer exists." >&2
    echo "Run 'Select Folder' to pick a valid folder." >&2
    exit 1
  fi

  echo "${dir}"
}

# target_mode — classify the current directory from its files. Echoes one of,
# checked in this order:
#   unit   terragrunt.hcl: run `terragrunt <verb>`
#   stack  terragrunt.stack.hcl: run `terragrunt stack run <verb>`
#   units  units below it: run `terragrunt run --all -- <verb>`
#   tofu   only *.tf files: run `tofu <verb>`
#   none   anything else
# Units that a stack run generated (.terragrunt-stack/) do not make a folder "units".
target_mode() {
  if [[ -f terragrunt.hcl ]]; then
    echo unit
  elif [[ -f terragrunt.stack.hcl ]]; then
    echo stack
  elif find . -mindepth 2 -name terragrunt.hcl -not -path '*/.terragrunt-cache/*' -not -path '*/.terraform/*' -not -path '*/.terragrunt-stack/*' -print -quit 2>/dev/null | grep -q .; then
    echo units
  elif compgen -G '*.tf' >/dev/null; then
    echo tofu
  else
    echo none
  fi
}

# target_label — the path below live/. The typed confirmation asks for it and
# the refusals name it. Outside live/ it is the folder name.
target_label() {
  local here
  here="$(pwd)"
  if [[ "${here}" == */live/* ]]; then
    echo "${here##*/live/}"
  else
    basename "${here}"
  fi
}

# target_provider — the provider, which is the folder right below live/
# (live/<provider>/...). A login must work before the first init, so it cannot
# come from Terraform output. Outside live/ the helper exits and says so.
target_provider() {
  local here provider
  here="$(pwd)"
  if [[ "${here}" != */live/* ]]; then
    echo "Error: '${here}' is not under live/. The provider is the folder right below live/ (live/<provider>/...)." >&2
    exit 1
  fi
  provider="${here##*/live/}"
  echo "${provider%%/*}"
}

# unit_dirs — echo the terragrunt unit directories at or below the cwd: the cwd
# itself when it has a terragrunt.hcl, else every unit below it, sorted. Units
# that a stack run generated under .terragrunt-stack/ are included, so the verbs
# can reach the machines of a stack file.
unit_dirs() {
  if [[ -f terragrunt.hcl ]]; then
    pwd
    return 0
  fi
  find "$(pwd)" -mindepth 2 -name terragrunt.hcl -not -path '*/.terragrunt-cache/*' -not -path '*/.terraform/*' -print 2>/dev/null \
    | sed 's|/terragrunt.hcl$||' | sort
}

# refuse <what> — the one-line refusal that every verb of a kind uses.
refuse() {
  echo "Error: '$(target_label)' $1." >&2
  exit 1
}

# pick_unit [--all] — make the cwd the one unit a verb acts on. A unit stays as
# it is. A folder of units, or a stack file, gets a picker of the unit paths
# below it (files only, no state read). With one unit there is no prompt. The
# choice is not saved. With --all the picker has an "all" entry: the helper
# then sets PICKED_ALL=1 and leaves the cwd alone.
pick_unit() {
  local with_all=0 units=() choice
  [[ "${1:-}" == "--all" ]] && with_all=1
  PICKED_ALL=0

  case "$(target_mode)" in
    unit) return 0 ;;
    units | stack) ;;
    *) refuse "holds no unit" ;;
  esac

  mapfile -t units < <(unit_dirs | sed "s|^$(pwd)/||")
  if [[ "${#units[@]}" -eq 0 ]]; then
    echo "Error: '$(target_label)' has no unit yet. For a stack file, run 'kube-tf init' to generate its units." >&2
    exit 1
  fi

  if [[ "${#units[@]}" -eq 1 && "${with_all}" -eq 0 ]]; then
    choice="${units[0]}"
  else
    choice=$({
      ((with_all)) && echo all
      printf '%s\n' "${units[@]}"
    } | fzf --prompt="Select unit: " --height=15 --border --bind='left-click:accept') || {
      echo "No unit selected." >&2
      exit 1
    }
  fi

  if [[ "${choice}" == all && "${with_all}" -eq 1 ]]; then
    # shellcheck disable=SC2034 # read by kube-start and kube-stop, which source this file
    PICKED_ALL=1
    return 0
  fi
  cd "${choice}" || exit 1
}

# for_each_unit <script> [args...] — run a verb-script in every unit below the
# cwd with KUBE_ALL_NODES=1, which makes select_nodes take every node without a
# prompt. A unit that fails is reported and the others still run. The exit
# status is non-zero when any unit failed.
for_each_unit() {
  local unit failed=()
  while IFS= read -r unit; do
    echo "== ${unit#"$(pwd)"/}"
    (cd "${unit}" && KUBE_ALL_NODES=1 "$@") || failed+=("${unit#"$(pwd)"/}")
  done < <(unit_dirs)
  if [[ "${#failed[@]}" -gt 0 ]]; then
    echo "Failed or refused in: ${failed[*]}" >&2
    return 1
  fi
}

# terragrunt_outputs — read terragrunt output -json into TF_OUTPUTS, or exit
# with a provider-neutral error. Call pick_unit first: this reads one unit.
terragrunt_outputs() {
  [[ "$(target_mode)" == unit ]] || refuse "is not one unit. Select a unit"
  # shellcheck disable=SC2034 # read by the verb-scripts that source this file
  TF_OUTPUTS=$(terragrunt output -json) || {
    echo "Error: 'terragrunt output' failed (see output above) — common causes:" >&2
    echo "  wrong directory, expired provider credentials (AWS/Azure/Proxmox)," >&2
    echo "  or no state applied yet." >&2
    exit 1
  }
}

# require_machines — the unit's outputs must list machines (control-plane, worker,
# static or extra node refs). For Start, Stop and Shell.
require_machines() {
  [[ -n "$(_node_refs_from_outputs "${TF_OUTPUTS}")" ]] || refuse "lists no machines"
}

# require_k8s_nodes — the unit's outputs must list Kubernetes nodes, which leaves
# out extra machines. For Tail and Status, which read RKE2 on the node.
require_k8s_nodes() {
  [[ -n "$(_node_refs_from_outputs "${TF_OUTPUTS}" k8s)" ]] || refuse "is not a cluster: it lists no Kubernetes nodes"
}

# require_control_plane — the unit's outputs must name a control-plane node
# (node_control_ref). For Kubeconfig and Secrets.
require_control_plane() {
  echo "${TF_OUTPUTS}" | jq -e '.node_control_ref.value // empty' >/dev/null 2>&1 || refuse "is not a cluster: it has no control-plane node"
}

# _node_refs_from_outputs <tf_outputs_json> [k8s] — echoes this unit's full node
# map (name -> {instance_id, ip, provider}), merging every source a unit
# might expose:
#   - control_plane_node_refs (a control-plane unit, split or merged layout)
#   - worker_node_refs (a standalone Proxmox node-pool unit — old split layout)
#   - node_pools.<pool>.worker_node_refs (the merged proxmox-cluster module —
#     every kube-examples Proxmox cluster now uses this single-unit layout;
#     its worker refs are nested per pool, not a top-level worker_node_refs
#     key, unlike the old split control-plane/ + node-pools/<pool>/ layout).
#   - static_nodes.<group>.node_refs (aws-cluster's fixed worker groups)
#   - extra_node_refs (machines the caller adds next to the cluster that aren't
#     Kubernetes nodes, such as a Windows dev machine; left out when the
#     second argument is "k8s", for verbs that talk to RKE2 on the node)
# Missing any of these contributes nothing (empty map), so this is safe
# whether the unit is control-plane-only, node-pool-only, or the merged
# composition. Shared by select_node, select_nodes and the require_* helpers so
# "which output(s) hold the node list" lives in one place.
#
# Autoscaled nodes (ASG/VMSS-managed) have no per-instance list Terraform
# tracks, so they never appear here.
_node_refs_from_outputs() {
  local tf_outputs="$1" scope="${2:-all}"
  echo "${tf_outputs}" | jq -c --arg scope "${scope}" '
    (.control_plane_node_refs.value // {}) as $cp
    | (.worker_node_refs.value // {}) as $w
    | ((.node_pools.value // {}) | [.[].worker_node_refs // {}] | add // {}) as $pool_workers
    | ((.static_nodes.value // {}) | [.[].node_refs // {}] | add // {}) as $static
    | (if $scope == "k8s" then {} else (.extra_node_refs.value // {}) end) as $extra
    | ($cp + $w + $pool_workers + $static + $extra)
    | if (. == {}) then empty else . end
  '
}

# select_node <tf_outputs_json> [k8s] — pick a node from this directory's node refs
# (see _node_refs_from_outputs; "k8s" leaves out extra_node_refs). Auto-selects with no prompt when there's
# exactly one node (single-node clusters see no change in behavior). Prompts
# with fzf (name + ip-or-instance_id) when there's more than one. Echoes the
# chosen node as a JSON object on stdout, with "name" merged in.
select_node() {
  local tf_outputs="$1" scope="${2:-all}" refs_json count picked_name
  refs_json=$(_node_refs_from_outputs "${tf_outputs}" "${scope}")

  if [[ -z "${refs_json}" ]]; then
    echo "Error: no control_plane_node_refs or worker_node_refs output in this directory." >&2
    echo "  (AWS/Azure node pools don't expose one — they're ASG/VMSS-managed," >&2
    echo "  so Terraform has no per-node list to read)" >&2
    exit 1
  fi

  count=$(echo "${refs_json}" | jq 'length')
  if [[ "${count}" -eq 0 ]]; then
    echo "Error: node refs output is empty." >&2
    exit 1
  fi

  if [[ "${count}" -eq 1 ]]; then
    echo "${refs_json}" | jq -c 'to_entries[0].value + {name: to_entries[0].key}'
    return 0
  fi

  picked_name=$(echo "${refs_json}" | jq -r 'to_entries[] | "\(.key)\t\(.value.ip // .value.instance_id)"' \
    | fzf --prompt="Select node: " --height=10 --border --with-nth=1,2 --delimiter='\t' \
          --bind='left-click:accept' \
    | cut -f1) || {
    echo "No node selected." >&2
    exit 1
  }

  echo "${refs_json}" | jq -c --arg n "${picked_name}" '.[$n] + {name: $n}'
}

# select_nodes <tf_outputs_json> — like select_node, for verbs that also make
# sense on the whole cluster (kube-start/kube-stop): with more than one node,
# the picker's first entry is "all". Echoes one JSON object per chosen node,
# with "name" merged in.
select_nodes() {
  local tf_outputs="$1" refs_json picked_name=all
  refs_json=$(_node_refs_from_outputs "${tf_outputs}")

  if [[ -z "${refs_json}" ]]; then
    echo "Error: no node refs output in this directory." >&2
    exit 1
  fi

  # KUBE_ALL_NODES=1 comes from for_each_unit: the owner already chose "all units".
  if [[ "$(echo "${refs_json}" | jq 'length')" -gt 1 && "${KUBE_ALL_NODES:-0}" != 1 ]]; then
    picked_name=$({
      printf 'all\tevery node\n'
      echo "${refs_json}" | jq -r 'to_entries[] | "\(.key)\t\(.value.ip // .value.instance_id)"'
    } | fzf --prompt="Select node: " --height=12 --border --with-nth=1,2 --delimiter='\t' \
          --bind='left-click:accept' \
      | cut -f1) || {
      echo "No node selected." >&2
      exit 1
    }
  fi

  echo "${refs_json}" | jq -c --arg n "${picked_name}" \
    'to_entries[] | select($n == "all" or .key == $n) | .value + {name: .key}'
}

# proxmox_host — parse the PVE hostname out of PROXMOX_VE_ENDPOINT, or exit.
# Echoes the hostname on success.
proxmox_host() {
  local host
  host=$(echo "${PROXMOX_VE_ENDPOINT:-}" | sed 's|https\?://||;s|:.*||')
  if [[ -z "${host}" ]]; then
    echo "Error: PROXMOX_VE_ENDPOINT is not set." >&2
    echo "  Put 'export PROXMOX_VE_ENDPOINT=...' in ~/.kube-compute/proxmox-endpoint" >&2
    echo "  (auto-sourced in every terminal) — see live/proxmox/README.md." >&2
    exit 1
  fi
  echo "${host}"
}

# proxmox_control_plane_dir — the unit to read the SSH account and key from.
# Node-pool workers share the control plane's Ansible SSH account and key
# (proxmox-node-pool exposes no ssh outputs of its own), so a worker unit reads
# them from a control-plane/ unit next to it. The first of these that holds a
# terragrunt.hcl wins: ./control-plane (the cwd is a folder of units),
# ../control-plane (the cwd is the control plane or a sibling pool) and
# ../../control-plane (the cwd is node-pools/<pool>). Otherwise the cwd itself
# is the unit, as in a single-node cluster.
proxmox_control_plane_dir() {
  local candidate
  for candidate in ./control-plane ../control-plane ../../control-plane; do
    if [[ -f "${candidate}/terragrunt.hcl" ]]; then
      (cd "${candidate}" && pwd)
      return 0
    fi
  done
  pwd
}

# proxmox_vm_ssh_key / proxmox_vm_ssh_user — SSH access to the node VM itself
# (not the PVE host). Source of truth is the control-plane unit's own applied
# state (terragrunt output -raw ansible_ssh_user / ansible_ssh_private_key_file
# — the same two outputs kube-compute's node-os-patch module itself consumes)
# so these can't drift from what Terraform actually applied. PROXMOX_VM_SSH_KEY/
# PROXMOX_VM_SSH_USER remain an explicit override (e.g. connecting with a
# personal key rather than Ansible's). Falls back further to the
# id_ed25519_kube_cluster/almalinux default (live/proxmox/README.md's Part 2
# setup — also Terraform's own variable default) when the control-plane unit
# has no state applied yet or predates these outputs. Requires port 22 open to
# the node (ingress_ports) — off by default, since the project's baseline
# design has no inbound SSH to nodes; Proxmox consumers opt into it
# explicitly.
proxmox_vm_ssh_user() {
  if [[ -n "${PROXMOX_VM_SSH_USER:-}" ]]; then
    echo "${PROXMOX_VM_SSH_USER}"
    return
  fi
  local cp_dir value
  cp_dir=$(proxmox_control_plane_dir)
  value=$(cd "${cp_dir}" && terragrunt output -raw ansible_ssh_user 2>/dev/null) || value=""
  echo "${value:-almalinux}"
}

proxmox_vm_ssh_key() {
  if [[ -n "${PROXMOX_VM_SSH_KEY:-}" ]]; then
    echo "${PROXMOX_VM_SSH_KEY}"
    return
  fi
  local cp_dir value
  cp_dir=$(proxmox_control_plane_dir)
  value=$(cd "${cp_dir}" && terragrunt output -raw ansible_ssh_private_key_file 2>/dev/null) || value=""
  value="${value:-${HOME}/.ssh/id_ed25519_kube_cluster}"
  echo "${value/#\~/${HOME}}"
}

# cluster_name_from_outputs <tf_outputs_json> — the name the cluster gives itself, which need not
# be its folder's: a repo may qualify it, with an environment say, so that two clusters of the same
# name stay apart. Falls back to the folder for a module that outputs no cluster_name.
cluster_name_from_outputs() {
  local name
  name=$(echo "$1" | jq -r '.cluster_name.value // empty')
  echo "${name:-$(basename "$(pwd)")}"
}

# kubeconfig_stem <tf_outputs_json> — names the kubeconfig file and, via rewrite_kubeconfig, the
# context/cluster/user inside it: the cluster name, plus the region for providers that have one so
# same-named clusters in different regions get distinct files and don't collide if their
# kubeconfigs are ever merged. Every verb that writes or reads that file takes the name from here.
kubeconfig_stem() {
  local name region
  name=$(cluster_name_from_outputs "$1")
  region=$(echo "$1" | jq -r '.aws_region.value // .azure_region.value // empty')
  echo "${name}${region:+-${region}}"
}

# rewrite_kubeconfig <server> <cluster_name> — read an rke2 kubeconfig on stdin,
# swap the loopback server for <server> and the default context/cluster/user
# name for <cluster_name>, write to stdout. Only a "default" that is a value of
# its own is renamed, never one inside a certificate blob.
rewrite_kubeconfig() {
  local server="$1" cluster_name="$2"
  sed -E "s|127\.0\.0\.1|${server}|g; s|(:[[:space:]]+)default[[:space:]]*$|\1${cluster_name}|"
}

# rke2_status_probe_script — echoes a shell script (as a single string) that,
# run on a node, prints exactly one of: not-started | in-progress | failed |
# complete. No status file to read (RKE2's own install writes nothing of the
# sort) — this derives status from the rke2-server/rke2-agent systemd unit
# RKE2's installer always creates, whichever role this node has. For a server
# node, "complete" additionally requires this node to show Ready in its own
# `kubectl get node <hostname>` — a unit merely being active only proves the
# process started, not that it finished joining etcd/the API. An agent node
# has no local kubeconfig to query, so unit-active is the strongest signal
# available from the node itself. Assumes RKE2's default node-name (the OS
# hostname) — this project's cloud-init/node-bootstrap templates don't
# override --node-name. Shared by kube-status's three provider branches so
# this probe logic isn't triplicated per-provider.
rke2_status_probe_script() {
  cat <<'PROBE'
if systemctl list-unit-files rke2-server.service 2>/dev/null | grep -q rke2-server; then
  UNIT=rke2-server
elif systemctl list-unit-files rke2-agent.service 2>/dev/null | grep -q rke2-agent; then
  UNIT=rke2-agent
else
  echo not-started
  exit 0
fi
if systemctl is-failed --quiet "$UNIT"; then
  echo failed
  exit 0
fi
if ! systemctl is-active --quiet "$UNIT"; then
  echo in-progress
  exit 0
fi
if [ "$UNIT" = rke2-server ]; then
  KUBECTL_BIN=$(command -v kubectl || echo /var/lib/rancher/rke2/bin/kubectl)
  READY=$("$KUBECTL_BIN" --kubeconfig /etc/rancher/rke2/rke2.yaml get node "$(hostname)" --no-headers 2>/dev/null | awk '{print $2}')
  if [ "$READY" = "Ready" ]; then echo complete; else echo in-progress; fi
else
  echo complete
fi
PROBE
}
