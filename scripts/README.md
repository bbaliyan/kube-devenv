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
| `select-cluster` | Pick and persist the active cluster directory. Lists both single-node clusters and, for a multi-node cluster, its root (applied as a whole) *and* its individual units. |
| `kube-run` | `cd` to the selected cluster directory and run a `kube-*` verb — what every VS Code Task actually calls. |
| `kube-cloud-login` | Authenticate against the selected cluster's provider (`aws sso login` / `az login` / Proxmox token refresh). Provider is inferred from the cluster's `live/<provider>/...` path, not from Terraform state, so this works before the first `init`. |
| `kube-init` | `terragrunt init` (multi-node root: `terragrunt run --all init`). |
| `kube-plan` | `terragrunt plan` (multi-node root: `terragrunt run --all plan`). |
| `kube-apply` | `terragrunt apply` (requires typing the cluster name; multi-node root: `terragrunt run --all apply` — cluster-facts first, then control-plane and node-pool concurrently). |
| `kube-start` | Start a stopped node (EC2 / Azure VM / Proxmox VM). Only needed when resuming a previously stopped cluster. Prompts to pick a node on a multi-node control-plane or Proxmox node pool. |
| `kube-status` | Report RKE2 join status for a node — `not-started` / `in-progress` / `failed` / `complete`, derived live from the node's own `rke2-server`/`rke2-agent` systemd unit and (for a server node) its own `kubectl get node` entry (SSM / Azure run-command, no inbound port; SSH for Proxmox). No status file involved. Prompts to pick a node — status is per-node, not shared cluster-wide. |
| `kube-upgrade-os` | Patch the OS on every node of the cluster (`ops/upgrade-os.sh` in kube-examples, which applies kube-compute's `node-os-patch` module): `dnf update -y`, reboot only when actually needed. Control-plane nodes one at a time, then workers. Requires typing the cluster name. Proxmox only — drives nodes over SSH, no AWS/Azure equivalent yet. |
| `kube-tail` | Live-tail a node's Ansible bootstrap log (`/tmp/kube-compute-bootstrap-<node>.log`, local to whatever machine runs `apply` — same for AWS and Proxmox) while `terragrunt apply` runs in another terminal. Terraform/OpenTofu unconditionally suppresses that provisioner's own console output because its config touches sensitive values, so this is the only way to see live, task-by-task Ansible progress during a run. Unlike `kube-status`/`kube-shell`, doesn't read `terragrunt output` (those outputs don't exist until the whole apply finishes) — globs for logfiles by cluster name instead, so it works precisely during an in-progress apply. Prompts to pick a node if more than one is bootstrapping. |
| `kube-kubeconfig` | Fetch kubeconfig and write it to `~/.kube/<cluster>.yaml`. Always targets the genesis node. |
| `kube-secrets` | Print in-cluster secrets (e.g. the ArgoCD admin password). |
| `kube-shell` | Break-glass shell (SSM session / Azure run-command / SSH for Proxmox), no inbound port required. Prompts to pick a node on a multi-node control-plane or Proxmox node pool. |
| `kube-destroy` | `terragrunt destroy` (requires typing the cluster name; multi-node root: `terragrunt run --all destroy` — control-plane and node-pool concurrently, then cluster-facts last). |
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

## Multi-node clusters: one root, several units

A single-node cluster is one Terragrunt unit — a directory with its own
`terragrunt.hcl`. A multi-node cluster (e.g. `live/proxmox/clusters/cluster-2`)
is instead a *root* directory with no `terragrunt.hcl` of its own, holding
several units — `control-plane/` and `node-pools/<pool>/` — wired by a
`dependency` block so Terragrunt knows their order.

`select-cluster` offers both the root and each unit. Which you pick depends on
the verb:

- **Lifecycle verbs** (`kube-init`/`kube-plan`/`kube-apply`/`kube-destroy`) work
  on the whole cluster — select the **root** and they use `terragrunt run --all`,
  which walks the dependency DAG (control plane up first on apply, down last on
  destroy). Run against a single unit, they act on just that unit.
- **Per-node / read verbs** (`kube-kubeconfig`/`kube-status`/`kube-shell`/
  `kube-start`) act on one unit's nodes, so select a **unit** — usually
  `control-plane` (that's where the kubeconfig/API live). Run against the root,
  they exit with a message telling you which unit to select.

## Picking a node on a multi-node cluster

A cluster's control-plane can have more than one node, and a Proxmox node pool can
have more than one worker. `kube-shell`, `kube-status`, and `kube-start` handle this by
reading the directory's `control_plane_node_refs` (control-plane) or `worker_node_refs`
(Proxmox node pool) output — a map of every node in that unit, not just the genesis
one — and prompting with `fzf` to pick one when there's more than a single entry. With
exactly one node (the common case), there's no prompt — same as before.

`kube-kubeconfig` deliberately stays pinned to the genesis node: unlike join status,
which is genuinely per-node (each node bootstraps independently), the kubeconfig's
server address gets rewritten to the cluster's shared FQDN/IP regardless of which node
the raw file was read from — so once a node has joined, which one you fetch from
doesn't change the result.

This doesn't work for AWS/Azure **node pools** specifically — those are
ASG/VMSS-managed, so Terraform has no per-instance list to read at all (`kube-shell`/
`kube-status`/`kube-start` don't work against an AWS/Azure node-pool directory today,
independent of this).
