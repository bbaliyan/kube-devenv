# kube-devenv

Pre-built, multi-arch (`linux/amd64` + `linux/arm64`) container image that gives every
operator the exact tested toolchain plus IDE wiring to drive the kube-node platform.

## What's inside

| Tool | Purpose |
|---|---|
| `tofu` | OpenTofu — IaC provisioning |
| `terragrunt` | Terragrunt — DRY wrapper + state management |
| `kubectl` | Kubernetes CLI (minor matches `k8s_version` in kube-node) |
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
kube-init         terragrunt init
kube-plan         terragrunt plan
kube-apply        terragrunt apply
kube-status       read bootstrap status (no inbound port: SSM / run-command / qm guest exec)
kube-watch        poll kube-status until complete or timeout
kube-kubeconfig   fetch kubeconfig and write to ~/.kube/<cluster>.yaml
kube-secrets      print in-cluster secrets (ArgoCD admin password, etc.)
kube-shell        break-glass shell (SSM session / qm terminal / az serial-console)
kube-destroy      destroy cluster (requires typing the cluster name)
select-cluster    set CLUSTER_DIR in the calling shell
```

## Using this image

### VS Code devcontainer (recommended)

Copy `examples/vscode/devcontainer.json` to your consumer repo's `.devcontainer/`:

```bash
mkdir -p .devcontainer
cp /path/to/kube-devenv/examples/vscode/devcontainer.json .devcontainer/devcontainer.json
```

Edit the `build.context` path (or replace with the published image digest once available),
then reopen the repo in VS Code → **Reopen in Container**.

### Build locally

The default `docker` driver doesn't support multi-platform builds. Create a
`docker-container` driver builder once:

```bash
docker buildx create --name multi --driver docker-container --use
```

Then build for your machine's architecture (single-platform loads into your local image
store; multi-platform requires `--push` to a registry and is handled by CI):

```bash
# Apple Silicon (arm64)
docker buildx build --platform linux/arm64 --load -t kube-devenv:local .

# Intel / AMD (amd64)
docker buildx build --platform linux/amd64 --load -t kube-devenv:local .
```

Single-arch (faster for local dev):

```bash
docker buildx build --platform linux/amd64 -t kube-devenv:local .
```

### Verify tool versions

```bash
docker run --rm kube-devenv:local bash -c "
  tofu version && terragrunt --version && kubectl version --client &&
  helm version && aws --version && az version &&
  sops --version && age --version && gitleaks version &&
  trivy --version && cosign version
"
```

## Version compatibility

The image's `kubectl` minor tracks `k8s_version` in kube-node (Kubernetes ±1 skew
policy). The `KUBE_DEVENV_VERSION` env var is exported from the image; kube-node will
use it in a future compatibility check.

On container start the banner prints:

```
kube-devenv v0.1.0 · kubectl 1.36.x · tofu 1.12.x · targets k8s 1.36
```

## Renovate

All tool versions in the `Dockerfile` are managed by Renovate. The `renovate.json` in
this repo is also the **shared preset** for kube-node and kube-examples — they extend it
once this repo is published:

```json
{ "extends": ["github>YOUR_ORG/kube-devenv"] }
```

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE) for bundled tool licenses.
