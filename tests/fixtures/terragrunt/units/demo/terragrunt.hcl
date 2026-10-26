# Template that the stack file stamps out once for each region.
terraform {
  source = "${get_repo_root()}/modules/demo"
}

inputs = {
  region = values.region
}
