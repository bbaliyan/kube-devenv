# kube-devenv verb-scripts

The kube-devenv image installs these commands to `/usr/local/bin/`. Each VS Code task
([README](../README.md#vs-code-tasks)) calls one of them. You can also run them in a
terminal, in a script or in a pipeline.

## The selected folder

The verbs act on **the selected folder**: any folder under `live/`. The kind of folder
comes from the files in it:

| Files in the folder | Kind | `kube-tf` runs |
|---|---|---|
| `terragrunt.hcl` | unit | `terragrunt <verb>` |
| `terragrunt.stack.hcl` | stack file | `terragrunt stack run <verb>` |
| units in folders below, and no `terragrunt.hcl` | folder of units | `terragrunt run --all -- <verb>` |
| only `*.tf` files | plain OpenTofu root | `tofu <verb>` |
| anything else | nothing to apply | an error, and nothing runs |

The words "unit" and "stack" mean what they mean in Terragrunt. A stack run writes a
`.terragrunt-stack/` folder into the folder. Add it to `.gitignore`.

`select-folder` saves the choice in `.vscode/.selected-folder`. `kube-run <verb>` goes to
the selected folder and runs the verb there. From a terminal you can also `cd` to the
folder and run the verb yourself.

## The verbs

| Script | Purpose |
|---|---|
| `select-folder` | Pick and save the selected folder. It lists every folder under `live/` that has a unit, a stack file or a `.tf` file, and every folder that holds units. It reads files only. You can type a path. `--list` prints the choices, `--current` prints the saved folder. |
| `kube-run` | Go to the selected folder and run a `kube-*` verb. Every VS Code task calls it. |
| `kube-cloud-login` | Log in to the provider: `aws sso login`, `az login` or the Proxmox token refresh. The provider is the folder right below `live/` (`live/<provider>/...`), so this works before the first init. A folder outside `live/` is an error. |
| `kube-tf` | `init`, `plan`, `apply` or `destroy` on the folder, with the tool that fits it (table above). `apply` and `destroy` print what they will touch, list the units of a folder of units with their count, and ask you to type the folder's path below `live/`. A stack file shows no count, because Terragrunt generates its units later. |
| `kube-start` | Start stopped machines. Works on any unit that lists machines. |
| `kube-stop` | Stop machines. Stopping all nodes of an AWS cluster also scales its autoscaled groups to zero. |
| `kube-shell` | Break-glass shell on a machine (SSM session, Azure run-command or SSH for Proxmox). |
| `kube-status` | Report the RKE2 join status of a node: `not-started`, `in-progress`, `failed` or `complete`. It asks the node itself, so no status file is involved. |
| `kube-tail` | Live-tail a node's bootstrap log. Apply returns before the node joins, so this is how to watch it. |
| `kube-kubeconfig` | Write the kubeconfig to `~/.kube/<cluster>.yaml`, or `~/.kube/<cluster>-<region>.yaml` where the provider has a region. `<cluster>` is the module's `cluster_name` output. |
| `kube-secrets` | Print in-cluster secrets, such as the Argo CD admin password. Run it after `kube-kubeconfig`. |
| `kube-proxmox-login` | Refresh the 8-hour Proxmox API token over SSH. `kube-cloud-login` calls it. |
| `kube-tasks-merge` | Write `.vscode/tasks.json` from the named task sets and the repo's `tasks-custom.json`. See "Task sets". |

## Which unit a verb acts on

Start, Stop, Shell, Tail, Status, Kubeconfig and Secrets act on **one unit**.

- If the selected folder is a unit, the verb acts on it.
- If the folder holds several units, or is a stack file, the verb shows a picker of the unit
  paths below the folder. The picker reads files only. With one unit there is no prompt.
- Start and Stop also offer **all**. They then act on every unit, one after the other. A unit
  that fails or is refused is reported, and the others still run.
- The choice is not saved. To act often on one unit, select that folder with `select-folder`.
- A stack file has units only after Terragrunt generated them. Run `kube-tf init` first.

After you choose a unit, the verb reads that unit's outputs once. If the unit is the wrong
kind, it stops with one line and does nothing else:

| Verb | The unit must | The refusal says |
|---|---|---|
| Start, Stop, Shell | list machines (`control_plane_node_refs`, `worker_node_refs`, `node_pools`, `static_nodes` or `extra_node_refs`) | `lists no machines` |
| Tail, Status | list Kubernetes nodes (the same, without `extra_node_refs`) | `is not a cluster: it lists no Kubernetes nodes` |
| Kubeconfig, Secrets | name a control-plane node (`node_control_ref`) | `is not a cluster: it has no control-plane node` |

A standalone machine that sits next to a cluster, in an `extra_node_refs` output
of the form `{ "<name>" = { instance_id = "...", ip = "...", provider = "aws" } }`, is a
machine and not a cluster. Start, Stop and Shell accept it. Tail and Status leave it out,
because they read RKE2 on the node.

Tail and Status accept a worker unit, because they read RKE2 on any Kubernetes node.
Kubeconfig and Secrets need the control-plane unit. Autoscaled nodes (AWS Auto Scaling
groups, Azure VMSS) are not listed: Terraform has no per-instance list for them.

## Task sets

The image ships three task sets, one file each in `/usr/share/kube-devenv/tasks/`:

| Set | Tasks |
|---|---|
| `core` | Select Folder, Cloud Login, Init, Plan, Apply, Destroy |
| `machines` | Start Node, Stop Node, Shell |
| `cluster` | Tail, Status, Kubeconfig, Secrets |

`kube-tasks-merge --sets core,machines` merges only the named sets. With no `--sets` it
merges all three. A repo names its sets in the `postStartCommand` of its
`devcontainer.json`. A pipeline has no buttons and calls `kube-tf` directly.

A task in `tasks-custom.json` can carry a `providers` array. `kube-tasks-merge` drops it
unless the repo has a matching `live/<provider>/` folder, and removes the key from the
output. A repo with no `live/`, or an empty one, keeps everything.

## Provider dispatch

`kube-tf` never branches on the provider. Terragrunt reads the provider module from the
unit's own `terragrunt.hcl`.

The other verbs call provider APIs, so they read `node_provider` from the unit's outputs
(`terragrunt output -json`) and branch on it. `kube-cloud-login` is the exception: it must
work before any state exists, so it reads the provider from the `live/<provider>/` folder.

## Picking a node

A unit can hold several nodes. Shell, Tail, Status, Start and Stop read the node refs of
the unit and ask with `fzf` when there is more than one. Start and Stop also offer "all".
With one node there is no prompt.

`kube-kubeconfig` reads from the control-plane node. Once a node has joined, which node you
read from does not change the result, because the server address is rewritten to the
cluster's shared name or IP.
