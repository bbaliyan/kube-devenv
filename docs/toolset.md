# Toolset review

The image is one full image. CI and people use the same image. There is no slim variant.

This table lists every tool the image pins. For each tool it shows who uses it, and whether the tool stays.
To add a tool, show one real use first. To remove one, check every repo that uses the image.

## Pinned tools

| Tool | Used by | Decision | Reason |
|---|---|---|---|
| OpenTofu (`tofu`) | kube-compute `make test-commit` (fmt, validate, test); kube-images `make test-commit` (fmt, validate); `kube-tf` | Keep | Core tool. |
| Terragrunt | `kube-tf` and the verb-scripts in this repo; consumer repos | Keep | Core tool. |
| tflint | Planned: kube-compute `make test-commit` | Keep | Lints Terraform modules. Added for the module checks that need it. |
| tflint AWS ruleset (`tflint-ruleset-aws`) | tflint, enabled in a repo's `.tflint.hcl` | Keep | Catches AWS errors that `tofu validate` misses, such as an invalid instance type. Baked in, so `tflint` needs no download at run time. |
| terraform-docs | Planned: kube-compute check that module README tables match the code | Keep | Writes the input and output tables of a module README, and checks that they are current. |
| Packer | kube-images `make test-commit` (`packer fmt`, `packer init`, `packer validate`) | Keep | Bakes the machine images. |
| clusterctl | Nothing | Remove | No repo calls it any more. kube-images no longer renders Cluster API manifests at bake time. |
| kubectl | kube-platform, kube-ci-workload, opnsense-observability-check (cluster jobs); `kube-kubeconfig`, `kube-secrets` | Keep | Core tool. |
| Helm | kube-platform, kube-ci-workload, opnsense-observability-check; `checks/helm-kubeconform.sh` | Keep | Core tool. |
| helm-unittest | kube-ci-workload `make` chart tests; opnsense-observability-check `make helm-unittest` | Keep | Runs the chart tests. |
| chart-testing (`ct`) | opnsense-observability-check `make ct-lint` | Keep | One public repo calls `ct lint`. Its schema files are in `/etc/ct`. |
| yamale | `ct lint` | Keep | `ct` needs it to validate `Chart.yaml`. |
| SOPS | The runbooks of consumer repos (`sops --encrypt`); the `sops` and `age` round trip in `tests/tools.sh` | Keep | People run it by hand. Terragrunt decrypts files with its own built-in function, so CI does not need the binary, but the people who edit the secret files do. |
| age | The same runbooks (`age-keygen`); `SOPS_AGE_KEY_FILE` in consumer devcontainers | Keep | SOPS needs it to make and open keys. |
| OpenBao CLI (`bao`) | Nothing | Remove | No repo uses OpenBao any more. |
| GitHub CLI (`gh`) | `.github/scripts/scan-image.sh` in this repo; the promote and comment scripts of consumer repos and kube-platform (`ci/post-comment.sh`) | Keep | Used in CI jobs. |
| gitleaks | `checks/secrets.sh` in every repo, through `make test-commit`; each repo's `.gitleaks.toml` points at the shared file | Keep | Part of the commit checks of every repo. |
| Trivy | kube-compute `make scan` (`trivy config`); `.github/scripts/scan-image.sh` | Keep | Scans IaC and the image. |
| cosign | Nothing | Remove | No repo or workflow calls it. Image attestations use the GitHub attestation actions. The SBOM check in `NOTICE` runs on the reader's machine. |
| yamlfmt | Nobody calls it from a Makefile, workflow or script. No repo has a `.yamlfmt` config. Only yamllint lints YAML. | Keep | Kept for formatting YAML by hand and for a possible future format check. |
| shfmt | `CONTRIBUTING.md` tells contributors to run `shfmt -i 2 -ci -d scripts/` | Keep | No Makefile calls it, but this repo documents it as the way to format scripts. It is small. |
| shellcheck | `make test-commit` in every repo | Keep | Core check. |
| hadolint | `make lint-dockerfile` in this repo, run in CI inside this image | Keep | The image checks its own Dockerfile with it. |
| kubeconform | kube-platform `ci/validate-schemas.sh`; `checks/helm-kubeconform.sh` (kube-ci-workload) | Keep | Core check. |
| promtool (from Prometheus) | kube-ci-workload `make` rule tests | Keep | Checks the alert rules. |
| yamllint | kube-images, kube-platform, kube-ci-workload `make test-commit` | Keep | Core check. |
| ansible-core | kube-images (`ansible-playbook` in role tests); kube-compute `node-bootstrap` (local-exec during apply) | Keep | Needed during apply. |
| ansible-lint | kube-images `make lint-ansible` | Keep | Core check. |
| boto3 | The `amazon.aws` collection (`aws_ssm` connection) | Keep | The collection needs it. |
| `amazon.aws` collection | kube-compute `node-bootstrap` (`aws_ssm` connection) | Keep | Playbooks reach AWS nodes with it. |
| `ansible.posix` collection | `kube-tf` enables the `profile_tasks` and `timer` callbacks | Keep | The verb-script depends on it. |
| `ansible.windows` collection | Used with Ansible on Windows nodes. | Keep | Provides the Windows modules. |
| fzf | `scripts/kube-common.sh` (unit and node pickers) | Keep | The VS Code tasks need it. |

## Other tools in the image

| Tool | Used by | Decision | Reason |
|---|---|---|---|
| AWS CLI | `kube-*` verb-scripts, kube-compute modules (`aws ssm`, `aws ec2`) | Keep | Core tool. |
| Session Manager plugin | `kube-shell` and `kube-tail` (`aws ssm start-session`) | Keep | The AWS CLI needs it for these commands. |
| `nsupdate` (`dnsutils`) | kube-compute `dns-registration` module (local-exec) | Keep | Apply fails without it. |
| `pre-commit` | `.pre-commit-config.yaml` and the devcontainer example in this repo | Keep | The repo config and the example `postCreateCommand` use it. |
| pyyaml | `tests/check-gitlab-ci.sh` in several repos; kube-platform `Makefile` | Keep | Repo test scripts import `yaml`. |
| `make`, `git`, `jq`, `curl`, `openssh-client`, `less`, `unzip`, `python3` | Makefiles, scripts, the install steps of this Dockerfile | Keep | Base tools. |

## How to repeat the search

1. Search each repo for the tool name in Makefiles, workflows, shell scripts, `.githooks`, devcontainer files and Terragrunt files.
2. Search the runbooks too, because people run some tools by hand.
3. If a Makefile target could call the tool and you cannot rule it out, keep the tool.
