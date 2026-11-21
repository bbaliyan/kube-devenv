variable "region" {
  default = "x"
}

resource "terraform_data" "r" {
  input = var.region
}

output "region" {
  value = var.region
}
