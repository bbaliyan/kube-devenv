# A plain OpenTofu root: only .tf files, so kube-tf runs tofu.
variable "region" {
  default = "x"
}

resource "terraform_data" "r" {
  input = var.region
}
