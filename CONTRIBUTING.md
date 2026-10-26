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
docker run --rm kube-devenv:local /usr/share/kube-devenv/checks/smoke.sh
```

Run the lint and the check-script tests:

```bash
make test-commit
make test-integration
```

`make test-integration` runs three kinds of test inside the image:

- `tests/checks.sh`: the shared check scripts in `checks/`.
- `tests/verbs.sh`: the `kube-*` verb-scripts, with stub tools.
- `tests/tools.sh`: one real, offline job for each tool that a repo of ours relies on
  (for example `kube-tf` through real Terragrunt and OpenTofu, or a `sops` and `age`
  round trip). A tool bump that changes that behaviour fails the PR that makes it.

When you add a tool to the image, add it to `checks/tools.txt` so the smoke test
verifies that it starts. If a repo relies on a particular job of the tool, add a case
for that job to `tests/tools.sh`. Do not add a case for a tool that needs a network or
a credential (`aws`, `az`, `gh`, `trivy`, `cosign`). Those stay at the smoke test.

The older manual check, still valid:

```bash
docker run --rm kube-devenv:local bash -c "
  tofu version && terragrunt --version && kubectl version --client &&
  helm version && aws --version &&
  sops --version && age --version && gitleaks version &&
  trivy --version && cosign version && shfmt --version && yamlfmt --version &&
  fzf --version && session-manager-plugin --version
"
```

## Verb-scripts

Scripts live in `scripts/` and are installed to `/usr/local/bin/` in the image.
They must be POSIX-compatible bash (`#!/usr/bin/env bash`, `set -euo pipefail`).
Run `shfmt -i 2 -ci -d scripts/` to check formatting.
