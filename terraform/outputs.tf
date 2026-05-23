###############################################################################
# outputs.tf
# Useful outputs printed after a successful apply. Handy for running gcloud,
# bq, or gsutil commands without copying values out of the console.
###############################################################################

output "logs_bucket" {
  description = "Cloud Storage bucket where application logs are uploaded."
  value       = google_storage_bucket.logs.name
}

output "function_source_bucket" {
  description = "Bucket holding the Cloud Function source zip."
  value       = google_storage_bucket.function_source.name
}

output "bigquery_dataset" {
  description = "BigQuery dataset that holds the logs table."
  value       = google_bigquery_dataset.logs.dataset_id
}

output "bigquery_table" {
  description = "Fully qualified BigQuery table reference."
  value       = "${var.project_id}.${google_bigquery_dataset.logs.dataset_id}.${google_bigquery_table.application_logs.table_id}"
}

output "loader_service_account" {
  description = "Service account used by the Cloud Function loader."
  value       = google_service_account.loader.email
}

output "analyst_service_account" {
  description = "Read-only analyst service account bound to the custom LogReadOnlyAnalyst role."
  value       = google_service_account.analyst.email
}

output "custom_role_id" {
  description = "Full ID of the custom IAM role created for log analysts."
  value       = google_project_iam_custom_role.log_read_only_analyst.id
}

output "loader_function_name" {
  description = "Name of the deployed Gen 2 Cloud Function."
  value       = google_cloudfunctions2_function.loader.name
}
