terraform {
  required_version = ">= 1.8.0"

  # Production and non-production applies must initialize this partial backend
  # with an approved *.s3.tfbackend file. Credentials belong in the standard
  # AWS environment/config chain, never in HCL or a backend configuration file.
  backend "s3" {}

  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.58"
    }
  }
}

provider "scaleway" {
  region = var.region
  zone   = var.zone
}
