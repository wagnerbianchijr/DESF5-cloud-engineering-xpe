###############################################################################
# providers.tf
# Provider configuration. Credentials are picked up from Application Default
# Credentials (ADC), so before "terraform apply" run:
#   gcloud auth application-default login
# Reference: https://cloud.google.com/docs/authentication/application-default-credentials
###############################################################################

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}
