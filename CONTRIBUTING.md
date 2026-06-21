# Contributing

Contributions are welcome. Please read this before opening a pull request.

## DCO — sign your commits

This project uses the [Developer Certificate of Origin](https://developercertificate.org/)
instead of a CLA. Add a `Signed-off-by` line to every commit:

```bash
git commit -s -m "your message"
```

PRs missing a `Signed-off-by` will fail the DCO check.

## Commit style

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add kube-start verb-script
fix: parse arm64 arch token in age install
chore: bump KUBECTL_VERSION to 1.36.2
```

This feeds [Release Please](https://github.com/googleapis/release-please) which
generates `CHANGELOG.md` and cuts releases automatically.

## Testing changes

Build the image locally before opening a PR:

```bash
docker buildx build --platform linux/amd64 -t kube-devenv:local .
```

For arm64 (Apple Silicon):

```bash
docker buildx build --platform linux/arm64 -t kube-devenv:local .
```

Verify all tools start:

```bash
docker run --rm kube-devenv:local bash -c "
  tofu version && terragrunt --version && kubectl version --client &&
  helm version && aws --version && az --version &&
  sops --version && age --version && gitleaks version &&
  trivy --version && cosign version && shfmt --version && yamlfmt --version
"
```

## Verb-scripts

Scripts live in `scripts/` and are installed to `/usr/local/bin/` in the image.
They must be POSIX-compatible bash (`#!/usr/bin/env bash`, `set -euo pipefail`).
Run `shfmt -i 2 -ci -d scripts/` to check formatting.
