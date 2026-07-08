#!/usr/bin/env bash
# kube-common.sh — shared helpers for the provider-dispatch verb-scripts
# (kube-status, kube-shell, kube-kubeconfig, kube-start). Sourced, not run
# directly: `source kube-common.sh` (found via PATH like the other scripts).

# terragrunt_outputs — read terragrunt output -json into TF_OUTPUTS, or exit
# with a provider-neutral error.
terragrunt_outputs() {
  TF_OUTPUTS=$(terragrunt output -json) || {
    echo "Error: 'terragrunt output' failed (see error above) — common causes:" >&2
    echo "  wrong directory, expired provider credentials (AWS/Azure/Proxmox)," >&2
    echo "  or no state applied yet." >&2
    exit 1
  }
}

# proxmox_host — parse the PVE hostname out of PROXMOX_VE_ENDPOINT, or exit.
# Echoes the hostname on success.
proxmox_host() {
  local host
  host=$(echo "${PROXMOX_VE_ENDPOINT:-}" | sed 's|https\?://||;s|:.*||')
  if [[ -z "${host}" ]]; then
    echo "Error: PROXMOX_VE_ENDPOINT is not set." >&2
    exit 1
  fi
  echo "${host}"
}

# rewrite_kubeconfig <server> <cluster_name> — read a k3s kubeconfig on stdin,
# swap the loopback server for <server> and the default context/cluster/user
# name for <cluster_name>, write to stdout.
rewrite_kubeconfig() {
  local server="$1" cluster_name="$2"
  sed "s|127\.0\.0\.1|${server}|g; s|default|${cluster_name}|g"
}
