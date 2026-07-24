# kube-devenv

[![Build and publish image](https://github.com/bbaliyan/kube-devenv/actions/workflows/build.yml/badge.svg)](https://github.com/bbaliyan/kube-devenv/actions/workflows/build.yml)
[![Latest release](https://img.shields.io/github/v/release/bbaliyan/kube-devenv)](https://github.com/bbaliyan/kube-devenv/releases/latest)
[![License: Apache-2.0](https://img.shields.io/github/license/bbaliyan/kube-devenv)](LICENSE)

Pre-built, multi-arch (`linux/amd64` + `linux/arm64`) container image providing a
consistent, pinned toolchain for consuming and operating the kube-\* platform. Used
by developers in VS Code devcontainers, by CI pipelines (dev/CI parity — same image
everywhere), and by operators managing clusters provisioned with
[kube-compute](https://github.com/bbaliyan/kube-compute).

## Quick start: VS Code devcontainer

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

Add mounts/env for whichever providers you actually use (AWS: `~/.aws`,
`AWS_PROFILE`; Azure: `~/.azure`, `ARM_SUBSCRIPTION_ID`/`ARM_TENANT_ID`) — see
[`examples/vscode/devcontainer.json`](https://github.com/bbaliyan/kube-devenv/blob/main/examples/vscode/devcontainer.json)
for a fuller example covering all three providers at once, plus VS Code extension
recommendations.

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
the GUI-launch case. Then click **Cloud Login** at the start of each session to fetch or
refresh the Proxmox API token (expires after 8h) — see [VS Code Tasks](#vs-code-tasks)
below.

Reopen your repo in VS Code → **Reopen in Container**. Renovate keeps the digest
current via automated PRs once configured.

## VS Code Tasks

Once the container is running, this is how you actually work day to day: click a task
instead of typing commands. Command Palette → **Tasks: Run Task**, or the status bar if
you have the
[Task Explorer / Tasks button](https://marketplace.visualstudio.com/items?itemName=actboy168.tasks)
extension. Installed automatically to `.vscode/tasks.json` on container start.

Typical order of use, top to bottom:

| Task | Purpose |
|---|---|
| **Select Cluster** | Pick which `live/<provider>/clusters/<name>/` directory the other tasks act on. Run this first — everything below operates on whatever's selected. |
| **Cloud Login** | Authenticate against the selected cluster's provider (AWS SSO / Azure CLI / Proxmox token refresh). Provider is inferred from the cluster's path, so this works even before the first Init. Run this before anything below — Init and Start Node both need it. |
| **Init** | `terragrunt init` for the selected cluster. |
| **Apply** | `terragrunt apply` for the selected cluster (typed confirmation required). |
| **Start Node** | Start a stopped node (EC2 / Azure VM / Proxmox VM). Only needed when resuming a previously stopped cluster — skip this for a brand-new Apply. |
| **Watch** | Poll bootstrap status until the node reports complete (or times out). |
| **Kubeconfig** | Fetch the cluster's kubeconfig and write it to `~/.kube/<cluster>.yaml`. |
| **Secrets** | Print in-cluster secrets (e.g. the ArgoCD admin password) — run after Kubeconfig. |
| **Shell** | Break-glass shell session on the node, no inbound port required. |
| **Destroy** | `terragrunt destroy` for the selected cluster (typed confirmation required). |

Prefer the terminal, or need this outside VS Code (CI, scripting)? Every task is a thin
wrapper around a plain CLI command — see
[`scripts/README.md`](scripts/README.md) for the full reference.

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
| `kube-*` verb-scripts | Provider-agnostic cluster operations — see [scripts/README.md](scripts/README.md) |

All versions are pinned in the `Dockerfile` via Renovate-managed `ARG` annotations and
update automatically via PR.

## Supply chain: what's in a given image, and is it safe

Every tagged release (`ghcr.io/bbaliyan/kube-devenv:vX.Y.Z`) gets:

- **A signed build provenance attestation and an SBOM**, published via GitHub's
  native [Artifact Attestations](https://docs.github.com/en/actions/security-guides/using-artifact-attestations-to-establish-provenance-for-builds)
  (not raw cosign or Docker Buildx's own `provenance`/`sbom` flags — GHCR doesn't
  implement the OCI Referrers API those rely on, so anything attached that way has
  nowhere to surface and is only reachable via raw digest lookups in build logs).
  These show up on this repo's
  [Attestations page](https://github.com/bbaliyan/kube-devenv/attestations) and
  verify with:
  ```bash
  gh attestation verify oci://ghcr.io/bbaliyan/kube-devenv:vX.Y.Z --owner bbaliyan
  ```
  which confirms both what's in the image (the SBOM) and that it was actually built
  by this repo's own `build.yml`, from a specific commit — not just "signed by
  someone with push access."
- **A [Trivy](https://github.com/aquasecurity/trivy) scan** for CRITICAL/HIGH
  vulnerabilities on every release build; results are uploaded to this repo's
  [Security tab](https://github.com/bbaliyan/kube-devenv/security/code-scanning).
  The scan doesn't block a release — check the Security tab before deploying if that
  matters for your use case.
- **A dependency version matrix**, in two places: the tool versions Renovate pins via
  Dockerfile `ARG`s (`tofu`, `terragrunt`, `kubectl`, `helm`, `sops`, `age`,
  `gitleaks`, `trivy`, `cosign`, `yamlfmt`, `shfmt`, `fzf`, `ansible-core`, `boto3`,
  the `amazon.aws` Ansible collection) are baked in as OCI
  labels (`io.kube-devenv.version.*`) — read them offline with
  `docker inspect ghcr.io/bbaliyan/kube-devenv:vX.Y.Z` or
  `crane config ghcr.io/bbaliyan/kube-devenv:vX.Y.Z`, no registry UI needed. The full
  set including tools that aren't Renovate-pinned (`aws`, `az`,
  `session-manager-plugin` track upstream "latest" at build time) is in each
  [GitHub Release](https://github.com/bbaliyan/kube-devenv/releases)' notes — built
  by actually running that release's image, not just reading the Dockerfile, so it's
  accurate even for the unpinned tools.

See [`.github/workflows/build.yml`](.github/workflows/build.yml) for the exact steps.

## Other ways to use this image

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
docker run --rm ghcr.io/bbaliyan/kube-devenv:latest bash -c "
  tofu version && terragrunt --version && kubectl version --client &&
  helm version && aws --version && az --version &&
  sops --version && age --version && gitleaks version &&
  trivy --version && cosign version && shfmt --version && yamlfmt --version &&
  fzf --version && session-manager-plugin --version &&
  ansible-playbook --version && ansible-galaxy collection list amazon.aws
"
```

## Version compatibility

The image's `kubectl` minor tracks `k8s_version` in kube-compute (Kubernetes ±1 skew
policy). On container start the banner prints:

```
kube-devenv 0.2.0 · kubectl 1.36.x · tofu 1.12.x · targets k8s 1.36
```

## Renovate

All tool versions in the `Dockerfile` are managed by Renovate. The `renovate.json` in
this repo also serves as the **shared preset** for kube-compute and kube-examples:

```json
{ "extends": ["github>bbaliyan/kube-devenv"] }
```

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE) for bundled tool licenses.
