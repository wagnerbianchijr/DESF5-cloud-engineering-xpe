###############################################################################
# storage.tf
# Two regional buckets in us-central1:
#   1. logs        : holds raw NDJSON application logs (Free Tier eligible)
#   2. function_src: holds the zipped Cloud Function source
#
# Key design choices:
#   * uniform_bucket_level_access = true so that ACLs cannot bypass IAM and
#     every grant flows through the same policy. This is the GCP recommended
#     mode. Reference:
#     https://cloud.google.com/storage/docs/uniform-bucket-level-access
#   * public_access_prevention = "enforced" denies the allUsers principal even
#     if a future binding tried to add it.
#   * versioning lets us recover from accidental deletion, which is cheap at
#     this volume and well below the 5 GB Free Tier ceiling.
#   * lifecycle rules transition objects to NEARLINE after N days and delete
#     them after the retention window, optimising cost. Reference:
#     https://cloud.google.com/storage/docs/lifecycle
###############################################################################

resource "google_storage_bucket" "logs" {
  name                        = "${var.name_prefix}-logs-${local.suffix}"
  project                     = var.project_id
  location                    = var.region
  storage_class               = "STANDARD"
  force_destroy               = var.bucket_force_destroy
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age = var.logs_nearline_after_days
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  lifecycle_rule {
    condition {
      age = var.logs_retention_days
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    purpose = "application-logs"
    env     = "lab"
  }

  depends_on = [google_project_service.enabled]
}

# Bucket holding the Cloud Function source zip. Separated so the loader does
# not accidentally trigger itself on uploads of its own source code.
resource "google_storage_bucket" "function_source" {
  name                        = "${var.name_prefix}-fn-src-${local.suffix}"
  project                     = var.project_id
  location                    = var.region
  storage_class               = "STANDARD"
  force_destroy               = true
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  depends_on = [google_project_service.enabled]
}

# Zip the Cloud Function source on every apply.
data "archive_file" "function_source" {
  type        = "zip"
  source_dir  = "${path.module}/function"
  output_path = "${path.module}/.build/function.zip"
}

resource "google_storage_bucket_object" "function_source_zip" {
  name   = "function-${data.archive_file.function_source.output_md5}.zip"
  bucket = google_storage_bucket.function_source.name
  source = data.archive_file.function_source.output_path
}

# Seed the logs bucket with the synthetic NDJSON file so the Eventarc trigger
# has something to react to on the first apply. Subsequent uploads happen via
# gsutil or any client SDK.
resource "google_storage_bucket_object" "sample_logs" {
  name         = "incoming/sample_logs.ndjson"
  bucket       = google_storage_bucket.logs.name
  source       = "${path.module}/../data/sample_logs.ndjson"
  content_type = "application/x-ndjson"

  # Ensure the Cloud Function is fully deployed before we drop the seed file,
  # otherwise the first event would be lost.
  depends_on = [google_cloudfunctions2_function.loader]
}
