# A stack file: Terragrunt generates one unit for each block below.
unit "one" {
  source = "${get_repo_root()}/units/demo"
  path   = "one"
  values = {
    region = "test-region-1"
  }
}

unit "two" {
  source = "${get_repo_root()}/units/demo"
  path   = "two"
  values = {
    region = "test-region-2"
  }
}
