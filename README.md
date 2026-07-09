# kube-devenv

Pre-built, multi-arch (`linux/amd64` + `linux/arm64`) container image providing a
consistent, pinned toolchain for consuming and operating the kube-\* platform. Used
by developers in VS Code devcontainers, by CI pipelines (dev/CI parity — same image
everywhere), and by operators managing clusters provisioned with
[kube-compute](https://github.com/bbaliyan/kube-compute).

## What's inside

| Tool | Purpose |
|---|---|
| `tofu` | OpenTofu — IaC provisioning |
| `terragrunt` | Terragrunt — DRY wrapper + state management |
| `kubectl` | Kubernetes CLI (minor tracks `k8s_version` in kube-compute) |
| `helm` | Helm package manager |
| `aws` | AWS CLI v2 |
| `az` | Azure CLI |
| `sops` + `age` | Secret encryption (SOPS + age backend) |
| `gitleaks` | Secret scanning (pre-commit + CI) |
| `trivy` | IaC misconfiguration + image vulnerability scanning |
| `cosign` | Image signing + SBOM verification |
| `yamlfmt` `shfmt` | Formatting linters |
| `pre-commit` `python3` `pyyaml` | Pre-commit framework + YAML parsing |
| `kube-*` verb-scripts | Provider-agnostic cluster operations (see below) |

All versions are pinned in the `Dockerfile` via Renovate-managed `ARG` annotations and
update automatically via PR.

## Operator verb-scripts

Installed to `/usr/local/bin/`. Run from the cluster directory
(`live/<provider>/clusters/<name>/`):

```
kube-init            terragrunt init
kube-plan            terragrunt plan
kube-apply           terragrunt apply (requires typing the cluster name)
kube-status          read bootstrap status (SSM / run-command, no inbound port; SSH for Proxmox)
kube-watch           poll kube-status until complete or timeout
kube-kubeconfig      fetch kubeconfig and write to ~/.kube/<cluster>.yaml
kube-secrets         print in-cluster secrets (ArgoCD admin password, etc.)
kube-shell           break-glass shell (SSM session / az serial-console, no inbound port; SSH for Proxmox)
kube-start           start a stopped node (EC2 / Azure VM / Proxmox VM via qm, root SSH to PVE host)
kube-destroy         destroy cluster (requires typing the cluster name)
kube-cloud-login     authenticate against the selected cluster's provider
                      (aws sso login / az login / Proxmox token refresh —
                      provider inferred from the cluster's live/<provider>/
                      path, so it works before terragrunt init)
kube-proxmox-login   refresh the 8h Proxmox API token over SSH (Proxmox only;
                      called by kube-cloud-login, or run directly)
select-cluster       pick and persist the active cluster directory
kube-run             cd to the selected cluster directory and run a kube-* verb
kube-tasks-merge     merge base tasks.json with a consumer's tasks-custom.json
```

## Using this image

### VS Code devcontainer (recommended)

Create `.devcontainer/devcontainer.json` in your repo with the following content.
The image is pinned with both a tag and a digest (`tag@sha256:...`). The tag is
human-readable; the digest makes the reference **immutable** — even if the tag is
repointed, Docker pulls exactly the layers that were built and signed. This protects
against supply chain attacks where a compromised registry rewrites a tag.
[Renovate](https://docs.renovatebot.com) keeps the digest current automatically via PR.

```jsonc
{
  // renovate: datasource=docker depName=ghcr.io/bbaliyan/kube-devenv
  "image": "ghcr.io/bbaliyan/kube-devenv:latest@sha256:295cb6d26fedbc7487d0265b86c6109638282e51c45d3d4649cf5dda99d65a0c",
  "name": "my-project",
  "initializeCommand": "mkdir -p ~/.aws ~/.kube ~/.config/age ~/.kube-compute",
  "postStartCommand": "mkdir -p .vscode && cp /usr/share/kube-devenv/tasks.json .vscode/tasks.json",
  "postCreateCommand": {
    "pre-commit": "pre-commit install || true",
    "proxmox-env": "printf '%s\\n' 'test -f /root/.kube-compute/proxmox && source /root/.kube-compute/proxmox' 'test -f /root/.kube-compute/proxmox-endpoint && source /root/.kube-compute/proxmox-endpoint' > /etc/kube-compute-env.sh && grep -q 'kube-compute-env.sh' ~/.bashrc || echo 'source /etc/kube-compute-env.sh' >> ~/.bashrc"
  },
  "mounts": [
    "source=${localEnv:HOME}/.aws,target=/root/.aws,type=bind,readonly",
    "source=${localEnv:HOME}/.kube,target=/root/.kube,type=bind",
    "source=${localEnv:HOME}/.config/age,target=/root/.config/age,type=bind,readonly",
    "source=${localEnv:HOME}/.kube-compute,target=/root/.kube-compute,type=bind",
    "source=/run/host-services/ssh-auth.sock,target=/ssh-agent,type=bind"
  ],
  "remoteEnv": {
    "SSH_AUTH_SOCK": "/ssh-agent",
    "BASH_ENV": "/etc/kube-compute-env.sh"
  },
  "remoteUser": "root"
}
```

Proxmox setup (one-time, on your host — not in the container):

```bash
mkdir -p ~/.kube-compute
echo "export PROXMOX_VE_ENDPOINT='https://pve.local:8006'" > ~/.kube-compute/proxmox-endpoint
```

`~/.kube-compute` is mounted and auto-sourced in every terminal — and in VS Code Tasks,
which run as `bash -c '...'` and don't source `~/.bashrc` at all, hence the `BASH_ENV`
above — so this survives container rebuilds and works regardless of whether VS Code was
launched from a terminal or from Finder/Spotlight/Dock, unlike forwarding
`PROXMOX_VE_ENDPOINT` via `remoteEnv`/`${localEnv:...}`, which silently does nothing in
the GUI-launch case. Then run `kube-proxmox-login` at the start of each session for the
token (expires after 8h) — see the [proxmox verb-script table](#operator-verb-scripts)
below.

A fuller example with VS Code extension recommendations is in
[`examples/vscode/devcontainer.json`](https://github.com/bbaliyan/kube-devenv/blob/main/examples/vscode/devcontainer.json).

Reopen your repo in VS Code → **Reopen in Container**. Renovate keeps the digest
current via automated PRs once configured.

### CI pipeline

Reference the image directly in your GitHub Actions workflow:

```yaml
jobs:
  validate:
    runs-on: ubuntu-latest
    container:
      # renovate: datasource=docker depName=ghcr.io/bbaliyan/kube-devenv
      image: ghcr.io/bbaliyan/kube-devenv:latest@sha256:295cb6d26fedbc7487d0265b86c6109638282e51c45d3d4649cf5dda99d65a0c
    steps:
      - uses: actions/checkout@v4
      - run: tofu fmt -check && tofu validate
```

### Build locally (contributors / kube-devenv development only)

```bash
# Apple Silicon (M1/M2/M3/M4 — arm64)
docker buildx build --platform linux/arm64 --load -t kube-devenv:local .

# Intel / AMD Mac or Linux (amd64)
docker buildx build --platform linux/amd64 --load -t kube-devenv:local .
```

> CI builds both architectures automatically on every `v*` tag via `.github/workflows/build.yml`.
> The `docker buildx create --name multi --driver docker-container --use` builder is only
> needed if you want to build and push multi-arch locally.

### Verify tool versions

```bash
docker run --rm ghcr.io/bbaliyan/kube-devenv:0.1.5 bash -c "
  tofu version && terragrunt --version && kubectl version --client &&
  helm version && aws --version && az --version &&
  sops --version && age --version && gitleaks version &&
  trivy --version && cosign version && shfmt --version && yamlfmt --version &&
  fzf --version && session-manager-plugin --version
"
```

## Version compatibility

The image's `kubectl` minor tracks `k8s_version` in kube-compute (Kubernetes ±1 skew
policy). On container start the banner prints:

```
kube-devenv 0.1.5 · kubectl 1.36.x · tofu 1.12.x · targets k8s 1.36
```

## Renovate

All tool versions in the `Dockerfile` are managed by Renovate. The `renovate.json` in
this repo also serves as the **shared preset** for kube-compute and kube-examples:

```json
{ "extends": ["github>bbaliyan/kube-devenv"] }
```

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE) for bundled tool licenses.
