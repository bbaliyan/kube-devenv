# A stack file: Terragrunt generates one unit for each block below, in two "regions".
unit "use1" {
  source = "${get_repo_root()}/units/demo"
  path   = "use1"
  values = {
    region = "us-east-1"
  }
}

unit "euw1" {
  source = "${get_repo_root()}/units/demo"
  path   = "euw1"
  values = {
    region = "eu-west-1"
  }
}
