# A single unit: a folder with its own terragrunt.hcl.
terraform {
  source = "${get_repo_root()}/modules/demo"
}

inputs = {
  region = "a"
}
