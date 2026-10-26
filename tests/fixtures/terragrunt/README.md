# Terragrunt test fixtures

`tests/tools.sh` copies this tree to a temporary folder, runs `git init` there, and
runs `kube-tf init`, `plan`, `apply` and `destroy` in each folder under `live/aws/`.
It uses the real Terragrunt and OpenTofu in the image, with local state and no cloud.
The only resource is the built-in `terraform_data`, so nothing is downloaded.

| Folder | Kind | `kube-tf` runs |
|---|---|---|
| `live/aws/unit` | a unit | `terragrunt <verb>` |
| `live/aws/env` | a folder of two units (`a`, `b`) | `terragrunt run --all -- <verb>` |
| `live/aws/stack` | a stack file that makes two units | `terragrunt stack run <verb>` |
| `live/aws/plain` | a plain OpenTofu root | `tofu <verb>` |

`modules/demo` is the one module that the units use. `units/demo` is the template that
the stack file stamps out. The units find the module with `get_repo_root()`, which is why
the test makes the copy a git repository.
