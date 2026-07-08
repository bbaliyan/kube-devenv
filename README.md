# kube-devenv

Pre-built, multi-arch (`linux/amd64` + `linux/arm64`) container image providing a
consistent, pinned toolchain for consuming and operating the kube-\* platform. Used
by developers in VS Code devcontainers, by CI pipelines (dev/CI parity — same image
everywhere), and by operators managing clusters provisioned with
[kube-node](https://github.com/bbaliyan/kube-node).

## What's inside

| Tool | Purpose |
|---|---|
| `tofu` | OpenTofu — IaC provisioning |
| `terragrunt` | Terragrunt — DRY wrapper + state management |
| `kubectl` | Kubernetes CLI (minor tracks `k8s_version` in kube-node) |
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
kube-status          read bootstrap status (no inbound port: SSM / run-command / qm guest exec)
kube-watch           poll kube-status until complete or timeout
kube-kubeconfig      fetch kubeconfig and write to ~/.kube/<cluster>.yaml
kube-secrets         print in-cluster secrets (ArgoCD admin password, etc.)
kube-shell           break-glass shell (SSM session / qm terminal / az serial-console)
kube-start           start a stopped node (EC2 / Azure VM / Proxmox VM)
kube-destroy         destroy cluster (requires typing the cluster name)
kube-proxmox-login   refresh the 8h Proxmox API token over SSH (Proxmox only)
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
  "initializeCommand": "mkdir -p ~/.aws ~/.kube ~/.config/age ~/.kube-node",
  "postStartCommand": "mkdir -p .vscode && cp /usr/share/kube-devenv/tasks.json .vscode/tasks.json",
  "postCreateCommand": {
    "pre-commit": "pre-commit install || true",
    "token": "grep -q '.kube-node/proxmox' ~/.bashrc || echo 'test -f /root/.kube-node/proxmox && source /root/.kube-node/proxmox' >> ~/.bashrc"
  },
  "mounts": [
    "source=${localEnv:HOME}/.aws,target=/root/.aws,type=bind,readonly",
    "source=${localEnv:HOME}/.kube,target=/root/.kube,type=bind",
    "source=${localEnv:HOME}/.config/age,target=/root/.config/age,type=bind,readonly",
    "source=${localEnv:HOME}/.kube-node,target=/root/.kube-node,type=bind",
    "source=/run/host-services/ssh-auth.sock,target=/ssh-agent,type=bind"
  ],
  "remoteEnv": {
    "SSH_AUTH_SOCK": "/ssh-agent",
    "PROXMOX_VE_ENDPOINT": "${localEnv:PROXMOX_VE_ENDPOINT}"
  },
  "remoteUser": "root"
}
```

Proxmox token: run `kube-proxmox-login` at the start of each session (the token expires
after 8h) — see the [proxmox verb-script table](#operator-verb-scripts) below.

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

The image's `kubectl` minor tracks `k8s_version` in kube-node (Kubernetes ±1 skew
policy). On container start the banner prints:

```
kube-devenv 0.1.5 · kubectl 1.36.x · tofu 1.12.x · targets k8s 1.36
```

## Renovate

All tool versions in the `Dockerfile` are managed by Renovate. The `renovate.json` in
this repo also serves as the **shared preset** for kube-node and kube-examples:

```json
{ "extends": ["github>bbaliyan/kube-devenv"] }
```

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE) for bundled tool licenses.
