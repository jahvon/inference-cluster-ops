terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source = "hashicorp/google"
      # 7.9.0 changed how preset-GPU machine families (G2) reconcile
      # guest_accelerator; see main.tf for why the block is declared explicitly.
      version = "~> 7.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
