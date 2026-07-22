terraform {
  required_version = ">= 1.12.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.20"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.20"
    }
  }
}

provider "google" {
  region                = var.region
  billing_project       = var.project_id
  user_project_override = true
}

provider "google-beta" {
  region                = var.region
  billing_project       = var.project_id
  user_project_override = true
}
