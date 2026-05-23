###############################################################################
# function.tf
# Gen 2 Cloud Function triggered by Eventarc on Cloud Storage object finalised
# events. The function reads the new NDJSON object from the logs bucket and
# loads it into the BigQuery application_logs table.
#
# Why Gen 2:
#   * Better cold-start performance and concurrency limits.
#   * Native Eventarc integration (Gen 1 used legacy GCS triggers).
# Reference:
#   https://cloud.google.com/functions/docs/2nd-gen/overview
###############################################################################

resource "google_cloudfunctions2_function" "loader" {
  name        = "${var.name_prefix}-loader"
  location    = var.region
  project     = var.project_id
  description = "Loads NDJSON objects from the logs bucket into BigQuery."

  build_config {
    runtime     = "python312"
    entry_point = "load_to_bigquery"
    source {
      storage_source {
        bucket = google_storage_bucket.function_source.name
        object = google_storage_bucket_object.function_source_zip.name
      }
    }
  }

  service_config {
    max_instance_count    = 3
    min_instance_count    = 0
    available_memory      = "256Mi"
    timeout_seconds       = 120
    service_account_email = google_service_account.loader.email
    environment_variables = {
      BQ_DATASET = google_bigquery_dataset.logs.dataset_id
      BQ_TABLE   = google_bigquery_table.application_logs.table_id
      BQ_PROJECT = var.project_id
    }
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.storage.object.v1.finalized"
    retry_policy          = "RETRY_POLICY_RETRY"
    service_account_email = google_service_account.loader.email

    event_filters {
      attribute = "bucket"
      value     = google_storage_bucket.logs.name
    }
  }

  depends_on = [
    google_project_service.enabled,
    google_project_iam_member.loader_eventarc_receiver,
    google_project_iam_member.loader_run_invoker,
    google_project_iam_member.gcs_pubsub_publisher,
    google_project_iam_member.loader_artifact_reader,
    google_bigquery_dataset_iam_member.loader_data_editor,
    google_project_iam_member.loader_job_user,
    google_storage_bucket_iam_member.loader_object_viewer,
    time_sleep.wait_for_eventarc_agent,
  ]
}
