###############################################################################
# main.tf
# Cross-cutting resources: API enablement and a random suffix used to keep
# bucket names globally unique across re-applies in the same project.
# Reference (services API):
#   https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/google_project_service
###############################################################################

resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  suffix = random_id.suffix.hex

  # APIs that must be on before any other resource is provisioned.
  required_apis = [
    "storage.googleapis.com",
    "bigquery.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "run.googleapis.com",
    "eventarc.googleapis.com",
    "artifactregistry.googleapis.com",
    "pubsub.googleapis.com",
    "logging.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
  ]
}

resource "google_project_service" "enabled" {
  for_each                   = toset(local.required_apis)
  project                    = var.project_id
  service                    = each.value
  disable_dependent_services = false
  disable_on_destroy         = false
}

# Surface the project number for use in IAM bindings to Google-managed service
# agents (such as the Cloud Storage service agent that publishes Eventarc).
data "google_project" "this" {
  project_id = var.project_id
}
