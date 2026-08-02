#!/usr/bin/env bash
# kube-common.sh — shared helpers for the provider-dispatch verb-scripts
# (kube-status, kube-shell, kube-kubeconfig, kube-start, kube-run,
# kube-cloud-login). Sourced, not run directly: `source kube-common.sh`
# (found via PATH like the other scripts).

# selected_cluster_dir — resolve the persisted 'Select Cluster' choice to an
# absolute path, or exit with a clear error. Echoes the path on success.
selected_cluster_dir() {
  local workspace persist_file dir
  workspace="${WORKSPACE_FOLDER:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  persist_file="${workspace}/.vscode/.selected-cluster"

  if [[ ! -f "${persist_file}" ]]; then
    echo "Error: no cluster selected — run 'Select Cluster' first." >&2
    exit 1
  fi

  dir="$(cat "${persist_file}")"

  if [[ ! -d "${dir}" ]]; then
    echo "Error: selected cluster directory '${dir}' no longer exists." >&2
    echo "Run 'Select Cluster' to pick a valid cluster." >&2
    exit 1
  fi

  echo "${dir}"
}

# cluster_provider <cluster_dir> — extract the provider name from a cluster's
# live/<provider>/... path. Deliberately path-based rather than reading
# terragrunt output: this must work before 'terragrunt init' has ever run
# (e.g. to authenticate for the first time), when no state/output exists yet.
cluster_provider() {
  local dir="$1" provider
  provider=$(echo "${dir}" | sed -n 's|.*/live/\([^/]*\)/.*|\1|p')
  if [[ -z "${provider}" ]]; then
    echo "Error: could not determine provider from cluster path '${dir}'" >&2
    echo "  (expected .../live/<provider>/clusters/<name>)" >&2
    exit 1
  fi
  echo "${provider}"
}

# cluster_name_from_pwd — derive the cluster name from the working directory.
# Works both from the cluster directory itself (single-node all-in-one layout,
# live/<provider>/clusters/<name>/) and from a subunit of a multi-node cluster
# (clusters/<name>/control-plane/ or clusters/<name>/node-pools/<pool>/): it
# takes the path segment directly under the nearest `clusters/` ancestor. That
# segment is the cluster_name. Falls back to the current directory's basename
# when not under a `clusters/` path. Kept in lockstep with kube-tail's inline
# copy (kube-tail deliberately doesn't source this file).
cluster_name_from_pwd() {
  local pwd_path after
  pwd_path="$(pwd)"
  if [[ "${pwd_path}" == */clusters/* ]]; then
    after="${pwd_path##*/clusters/}"   # e.g. "cluster-2/control-plane" or "cluster-1"
    echo "${after%%/*}"                # -> "cluster-2" or "cluster-1"
  else
    echo "$(basename "${pwd_path}")"
  fi
}

# terragrunt_run_mode — classify the current directory for the lifecycle verbs
# (kube-init/kube-plan/kube-apply/kube-destroy). Echoes one of:
#   single  the cwd is a single terragrunt unit (has its own terragrunt.hcl)
#   all     the cwd is a multi-unit cluster root (no terragrunt.hcl of its own
#           but units live beneath it) — drive it with `terragrunt run --all`
#   none    neither (a misconfigured / wrong directory)
# The multi-unit case is a multi-node cluster like proxmox/clusters/cluster-2,
# whose control-plane/ and node-pools/<pool>/ units terragrunt orders by their
# dependency DAG.
terragrunt_run_mode() {
  if [[ -f terragrunt.hcl ]]; then
    echo single
  elif find . -mindepth 2 -name terragrunt.hcl -not -path '*/.terragrunt-cache/*' -print -quit 2>/dev/null | grep -q .; then
    echo all
  else
    echo none
  fi
}

# resolve_control_plane_unit — make cluster-level verbs (kube-kubeconfig)
# agnostic to single- vs multi-node layout. A single-node cluster and each unit
# of a multi-node cluster are already terragrunt units (own terragrunt.hcl), so
# this is a no-op there. When the cwd is a multi-node cluster ROOT (no
# terragrunt.hcl of its own), cd into its control-plane/ unit — the kubeconfig
# and API server always live on a server node, so that unit is the unambiguous
# source regardless of how many workers the cluster has.
resolve_control_plane_unit() {
  [[ -f terragrunt.hcl ]] && return 0
  if [[ -f control-plane/terragrunt.hcl ]]; then
    echo "Multi-node cluster root: reading the kubeconfig from the control-plane unit." >&2
    cd control-plane || exit 1
    return 0
  fi
  echo "Error: '$(pwd)' has no terragrunt.hcl and no control-plane/ unit to read from." >&2
  exit 1
}

# terragrunt_outputs — read terragrunt output -json into TF_OUTPUTS, or exit
# with a provider-neutral error. Per-node/read verbs operate on a single unit,
# so if the cwd is a multi-node cluster root (no terragrunt.hcl of its own),
# point the operator at the specific unit to select instead.
terragrunt_outputs() {
  if [[ ! -f terragrunt.hcl && "$(terragrunt_run_mode)" == "all" ]]; then
    local rel
    rel="$(pwd | sed 's|.*/live/|live/|')"
    echo "Error: '$(pwd)' is a multi-node cluster root, not a single unit." >&2
    echo "  Per-node verbs (kube-kubeconfig/kube-status/kube-shell/kube-start) act on" >&2
    echo "  one unit. Select the control plane (for the kubeconfig/API) or a node pool:" >&2
    echo "    select-cluster ${rel}/control-plane" >&2
    exit 1
  fi
  TF_OUTPUTS=$(terragrunt output -json) || {
    echo "Error: 'terragrunt output' failed (see output above) — common causes:" >&2
    echo "  wrong directory, expired provider credentials (AWS/Azure/Proxmox)," >&2
    echo "  or no state applied yet." >&2
    exit 1
  }
}

# _node_refs_from_outputs <tf_outputs_json> — echoes this unit's
# control_plane_node_refs (control-plane) or worker_node_refs (Proxmox node
# pool) map, whichever is present, or empty string if neither is. Shared by
# select_node and select_node_any_unit so "which output holds the node list"
# lives in one place.
#
# AWS/Azure node pools have no equivalent output (ASG/VMSS-managed — no
# per-instance list Terraform tracks) — callers see empty string there, same
# as an unapplied unit.
_node_refs_from_outputs() {
  local tf_outputs="$1" refs_key refs_json=""
  for refs_key in control_plane_node_refs worker_node_refs; do
    refs_json=$(echo "${tf_outputs}" | jq -c --arg k "${refs_key}" '.[$k].value // empty')
    [[ -n "${refs_json}" && "${refs_json}" != "null" ]] && break
    refs_json=""
  done
  echo "${refs_json}"
}

# select_node <tf_outputs_json> — pick a node from this directory's node refs
# (see _node_refs_from_outputs). Auto-selects with no prompt when there's
# exactly one node (single-node clusters see no change in behavior). Prompts
# with fzf (name + ip-or-instance_id) when there's more than one. Echoes the
# chosen node as a JSON object on stdout, with "name" merged in.
select_node() {
  local tf_outputs="$1" refs_json count picked_name
  refs_json=$(_node_refs_from_outputs "${tf_outputs}")

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

# terragrunt_target_units — echo the terragrunt unit directories to search for
# nodes from the cwd: itself when the cwd is a single unit (has its own
# terragrunt.hcl), or control-plane + every node-pools/<pool> unit when the
# cwd is a multi-node cluster root (terragrunt_run_mode == "all"). Used by
# select_node_any_unit so per-node verbs work whether the operator selected a
# specific unit or the cluster root itself.
terragrunt_target_units() {
  if [[ -f terragrunt.hcl ]]; then
    pwd
    return 0
  fi
  if [[ "$(terragrunt_run_mode)" != "all" ]]; then
    echo "Error: '$(pwd)' has no terragrunt.hcl and no node-pool units beneath it." >&2
    exit 1
  fi
  [[ -f control-plane/terragrunt.hcl ]] && echo "$(pwd)/control-plane"
  if [[ -d node-pools ]]; then
    find "$(pwd)/node-pools" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r d; do
      [[ -f "${d}/terragrunt.hcl" ]] && echo "${d}"
    done
  fi
}

# select_node_any_unit — like select_node, but works whether the cwd is a
# single terragrunt unit or a multi-node cluster root: aggregates every node
# from every unit terragrunt_target_units finds into one fzf list (labeled
# "unit  name  ip-or-instance_id"), auto-selecting with no prompt when
# there's exactly one node total across all of them. Echoes the chosen node
# as JSON, merging in "name", "provider" (that unit's node_provider), and
# "unit" (absolute path to the unit directory the node came from) — callers
# cd into "unit" before dispatching further provider calls (e.g. Azure's
# resource_group_name) so those run in the right unit's context.
select_node_any_unit() {
  local unit units=() rows="" tf_outputs provider refs_json count picked_name

  mapfile -t units < <(terragrunt_target_units)
  if [[ "${#units[@]}" -eq 0 ]]; then
    echo "Error: no terragrunt units found under '$(pwd)'." >&2
    exit 1
  fi

  for unit in "${units[@]}"; do
    tf_outputs=$(cd "${unit}" && terragrunt output -json 2>/dev/null) || continue
    provider=$(echo "${tf_outputs}" | jq -r '.node_provider.value // empty')
    refs_json=$(_node_refs_from_outputs "${tf_outputs}")
    [[ -z "${refs_json}" ]] && continue
    rows+=$(echo "${refs_json}" | jq -c --arg unit "${unit}" --arg provider "${provider}" \
      'to_entries[] | .value + {name: .key, unit: $unit, provider: $provider}')$'\n'
  done
  rows="${rows%$'\n'}"

  if [[ -z "${rows}" ]]; then
    echo "Error: no nodes found in any unit under '$(pwd)' (state not applied yet?)." >&2
    exit 1
  fi

  count=$(echo "${rows}" | wc -l | tr -d ' ')
  if [[ "${count}" -eq 1 ]]; then
    echo "${rows}"
    return 0
  fi

  picked_name=$(echo "${rows}" | jq -r '"\(.unit | sub(".*/clusters/"; ""))\t\(.name)\t\(.ip // .instance_id)"' \
    | fzf --prompt="Select node: " --height=15 --border --with-nth=1,2,3 --delimiter='\t' \
          --bind='left-click:accept' \
    | cut -f2) || {
    echo "No node selected." >&2
    exit 1
  }

  echo "${rows}" | jq -c --arg n "${picked_name}" 'select(.name == $n)' | head -1
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

# proxmox_control_plane_dir — resolve the control-plane terragrunt unit
# directory for the cluster the cwd belongs to, regardless of which unit the
# cwd actually is: already inside control-plane/, inside a node-pools/<pool>/
# worker unit (walk up to the cluster root, then into control-plane/), or a
# single-node all_in_one cluster (no control-plane/ subdir at all — the
# cluster-root unit itself IS the control plane). Node-pool workers share the
# control plane's Ansible SSH account/key (proxmox-node-pool exposes no ssh
# outputs of its own — kube-examples' os-patch tooling established this same
# pattern), so ssh creds always get read from here.
proxmox_control_plane_dir() {
  local pwd_path clusters_root cp_dir
  pwd_path="$(pwd)"
  if [[ "${pwd_path}" != */clusters/* ]]; then
    echo "Error: '${pwd_path}' is not under a live/<provider>/clusters/ path." >&2
    exit 1
  fi
  clusters_root="${pwd_path%%/clusters/*}/clusters/$(echo "${pwd_path##*/clusters/}" | cut -d/ -f1)"
  cp_dir="${clusters_root}/control-plane"
  if [[ -d "${cp_dir}" ]]; then
    echo "${cp_dir}"
  else
    echo "${clusters_root}"
  fi
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

# rewrite_kubeconfig <server> <cluster_name> — read an rke2 kubeconfig on stdin,
# swap the loopback server for <server> and the default context/cluster/user
# name for <cluster_name>, write to stdout.
rewrite_kubeconfig() {
  local server="$1" cluster_name="$2"
  sed "s|127\.0\.0\.1|${server}|g; s|default|${cluster_name}|g"
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
