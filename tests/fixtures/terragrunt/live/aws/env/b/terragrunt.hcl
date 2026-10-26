# The second unit of the folder of units.
terraform {
  source = "${get_repo_root()}/modules/demo"
}

inputs = {
  region = "b"
}
