terraform {
  required_version = ">= 1.8.0"
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
