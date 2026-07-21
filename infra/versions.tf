terraform {
  required_version = ">= 1.14.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "7.40.0"
    }
  }
}

provider "google" {
  region                = var.region
  billing_project       = var.project_id
  user_project_override = true
}
