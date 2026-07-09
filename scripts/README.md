# kube-devenv verb-scripts

Installed to `/usr/local/bin/` by the kube-devenv image. These are the plain CLI
commands behind every [VS Code Task](../README.md#vs-code-tasks) — use them directly
from a terminal when you don't want to click a button (CI, scripting, headless work,
or just a faster habit).

Most of these operate on **the selected cluster** and must be run from that cluster's
directory (`live/<provider>/clusters/<name>/`). `select-cluster` and `kube-run` are how
the VS Code Tasks get there automatically; from a terminal you can either `cd` there
yourself or use `kube-run <verb>` the same way the tasks do.

| Script | Purpose |
|---|---|
| `select-cluster` | Pick and persist the active cluster directory. |
| `kube-run` | `cd` to the selected cluster directory and run a `kube-*` verb — what every VS Code Task actually calls. |
| `kube-cloud-login` | Authenticate against the selected cluster's provider (`aws sso login` / `az login` / Proxmox token refresh). Provider is inferred from the cluster's `live/<provider>/...` path, not from Terraform state, so this works before the first `init`. |
| `kube-init` | `terragrunt init` |
| `kube-plan` | `terragrunt plan` |
| `kube-apply` | `terragrunt apply` (requires typing the cluster name) |
| `kube-start` | Start a stopped node (EC2 / Azure VM / Proxmox VM). Only needed when resuming a previously stopped cluster. Prompts to pick a node on a multi-node spine or Proxmox worker pool. |
| `kube-status` | Read bootstrap status (SSM / Azure run-command, no inbound port; SSH for Proxmox). Always targets the genesis node. |
| `kube-watch` | Poll `kube-status` until it reports complete or times out. |
| `kube-kubeconfig` | Fetch kubeconfig and write it to `~/.kube/<cluster>.yaml`. Always targets the genesis node. |
| `kube-secrets` | Print in-cluster secrets (e.g. the ArgoCD admin password). |
| `kube-shell` | Break-glass shell (SSM session / Azure run-command / SSH for Proxmox), no inbound port required. Prompts to pick a node on a multi-node spine or Proxmox worker pool. |
| `kube-destroy` | `terragrunt destroy` (requires typing the cluster name). |
| `kube-proxmox-login` | Refresh the 8h Proxmox API token over SSH. Proxmox-only; called internally by `kube-cloud-login`, or run directly. |
| `kube-tasks-merge` | Merge the base `tasks.json` with a consumer repo's `tasks-custom.json`. |

## How provider dispatch works

`kube-init`/`kube-plan`/`kube-apply`/`kube-destroy` never branch on provider — they
just call plain `terragrunt <verb>`, and Terragrunt resolves the right provider module
from the `terragrunt.hcl` in the current directory.

`kube-status`/`kube-shell`/`kube-kubeconfig`/`kube-start` do call provider-specific
APIs, so they read `node_provider` from `terragrunt output -json` (the cluster's own
applied state) and branch on it — correct by construction, since a cluster under
`live/aws/...` can only ever produce `node_provider = "aws"`.

`kube-cloud-login` is the exception: it needs to work *before* `terragrunt init` has
ever run, when there's no state to read `node_provider` from. It infers the provider
from the cluster's directory path instead (`live/<provider>/clusters/<name>/...`).

## Picking a node on a multi-node cluster

A spine can have more than one control-plane node, and a Proxmox worker pool can have
more than one worker. `kube-shell` and `kube-start` handle this by reading the
directory's `control_plane_node_refs` (spine) or `worker_node_refs` (Proxmox worker
pool) output — a map of every node in that unit, not just the genesis one — and
prompting with `fzf` to pick one when there's more than a single entry. With exactly
one node (the common case), there's no prompt — same as before.

`kube-status`/`kube-kubeconfig` deliberately stay pinned to the genesis node: HA
control-plane nodes should reflect the same cluster-wide bootstrap/kubeconfig state, so
picking a specific one doesn't add anything.

This doesn't work for AWS/Azure **worker pools** specifically — those are
ASG/VMSS-managed, so Terraform has no per-instance list to read at all (`kube-shell`/
`kube-status`/`kube-start` don't work against an AWS/Azure worker-pool directory today,
independent of this).
