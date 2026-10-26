variable "region" {
  default = "x"
}

resource "terraform_data" "r" {
  input = var.region
}
