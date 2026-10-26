# One of two units in a folder of units (live/aws/env has no terragrunt.hcl of its own).
terraform {
  source = "${get_repo_root()}/modules/demo"
}

inputs = {
  region = "a"
}
