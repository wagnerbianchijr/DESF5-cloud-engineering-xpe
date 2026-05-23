###############################################################################
# variables.tf
# All inputs the module accepts. Defaults follow the Free Tier eligible region
# (us-central1) and reasonable retention windows. Override via terraform.tfvars.
###############################################################################

variable "project_id" {
  description = "GCP project ID where every resource will be created."
  type        = string
}

variable "region" {
  description = "Region for the bucket, dataset, and Cloud Function. Must be one of the Free Tier regions for Cloud Storage (us-east1, us-west1, us-central1)."
  type        = string
  default     = "us-central1"

  validation {
    condition     = contains(["us-east1", "us-west1", "us-central1"], var.region)
    error_message = "Region must be one of us-east1, us-west1, us-central1 to stay inside the Cloud Storage Always Free quota."
  }
}

variable "name_prefix" {
  description = "Prefix prepended to every resource name. Keeps names unique across re-applies."
  type        = string
  default     = "desafio-final"
}

variable "bucket_force_destroy" {
  description = "Whether terraform destroy is allowed to delete a non-empty bucket. Keep false in production."
  type        = bool
  default     = true
}

variable "logs_retention_days" {
  description = "After this many days, objects in the logs bucket are deleted by the Lifecycle rule."
  type        = number
  default     = 365
}

variable "logs_nearline_after_days" {
  description = "After this many days, objects are transitioned to NEARLINE storage class to reduce cost."
  type        = number
  default     = 30
}

variable "bigquery_table_expiration_ms" {
  description = "Default expiration for tables inside the dataset, in milliseconds. 0 disables the default."
  type        = number
  default     = 31536000000 # 365 days
}

variable "analyst_principal" {
  description = "Optional user or group to bind to the analyst custom role. Format: user:email or group:email. Leave empty to bind only the analyst service account."
  type        = string
  default     = ""
}
