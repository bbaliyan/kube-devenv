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

# terragrunt_outputs — read terragrunt output -json into TF_OUTPUTS, or exit
# with a provider-neutral error.
terragrunt_outputs() {
  TF_OUTPUTS=$(terragrunt output -json) || {
    echo "Error: 'terragrunt output' failed (see output above) — common causes:" >&2
    echo "  wrong directory, expired provider credentials (AWS/Azure/Proxmox)," >&2
    echo "  or no state applied yet." >&2
    exit 1
  }
}

# select_node <tf_outputs_json> — pick a node from this directory's
# control_plane_node_refs (spine) or worker_node_refs (Proxmox worker pool),
# whichever is present. Auto-selects with no prompt when there's exactly one
# node (single-node clusters see no change in behavior). Prompts with fzf
# (name + ip-or-instance_id) when there's more than one. Echoes the chosen
# node as a JSON object on stdout, with "name" merged in.
#
# AWS/Azure worker pools have no equivalent output (ASG/VMSS-managed — no
# per-instance list Terraform tracks), so this errors clearly there rather
# than silently targeting nothing.
select_node() {
  local tf_outputs="$1" refs_key refs_json="" count picked_name

  for refs_key in control_plane_node_refs worker_node_refs; do
    refs_json=$(echo "${tf_outputs}" | jq -c --arg k "${refs_key}" '.[$k].value // empty')
    if [[ -n "${refs_json}" && "${refs_json}" != "null" ]]; then
      break
    fi
    refs_json=""
  done

  if [[ -z "${refs_json}" ]]; then
    echo "Error: no control_plane_node_refs or worker_node_refs output in this directory." >&2
    echo "  (AWS/Azure worker pools don't expose one — they're ASG/VMSS-managed," >&2
    echo "  so Terraform has no per-node list to read)" >&2
    exit 1
  fi

  count=$(echo "${refs_json}" | jq 'length')
  if [[ "${count}" -eq 0 ]]; then
    echo "Error: ${refs_key} is empty." >&2
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

# proxmox_vm_ssh_key / proxmox_vm_ssh_user — SSH access to the node VM itself
# (not the PVE host). Defaults match live/proxmox/README.md's Part 2 setup:
# the id_ed25519_kube_cluster key, ubuntu user. Requires port 22 open to the
# node (ingress_ports) — off by default, since the project's baseline design
# has no inbound SSH to nodes; Proxmox consumers opt into it explicitly.
proxmox_vm_ssh_key() { echo "${PROXMOX_VM_SSH_KEY:-${HOME}/.ssh/id_ed25519_kube_cluster}"; }
proxmox_vm_ssh_user() { echo "${PROXMOX_VM_SSH_USER:-ubuntu}"; }

# rewrite_kubeconfig <server> <cluster_name> — read a k3s kubeconfig on stdin,
# swap the loopback server for <server> and the default context/cluster/user
# name for <cluster_name>, write to stdout.
rewrite_kubeconfig() {
  local server="$1" cluster_name="$2"
  sed "s|127\.0\.0\.1|${server}|g; s|default|${cluster_name}|g"
}
