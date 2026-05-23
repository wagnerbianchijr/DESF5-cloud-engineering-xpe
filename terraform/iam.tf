###############################################################################
# iam.tf
# Identity and access for the lab. Two service accounts illustrate the two
# personas the assignment asks for:
#
#   loader  : a workload identity. Trusted to read the logs bucket and to
#             write rows into the BigQuery table. Used by the Cloud Function.
#   analyst : a least-privilege consumer. May list the bucket metadata, read
#             objects, and query the table, but cannot mutate anything.
#
# Predefined roles are bound at the narrowest possible scope (bucket, dataset)
# rather than the project, as recommended by GCP. Reference:
#   https://cloud.google.com/iam/docs/granting-changing-revoking-access
#
# In addition, the assignment requires a CUSTOM role. We define
# LogReadOnlyAnalyst, which combines the precise list of permissions a log
# viewer needs without granting the broader objectViewer or dataViewer roles.
###############################################################################

# ----- Workload service accounts ---------------------------------------------

resource "google_service_account" "loader" {
  account_id   = "${var.name_prefix}-loader"
  display_name = "Cloud Function loader for ${var.name_prefix}"
  project      = var.project_id
}

resource "google_service_account" "analyst" {
  account_id   = "${var.name_prefix}-analyst"
  display_name = "Read-only log analyst for ${var.name_prefix}"
  project      = var.project_id
}

# ----- Custom role -----------------------------------------------------------

# A custom role with the minimum permissions a log analyst needs:
#   * inspect bucket metadata
#   * read object contents
#   * query the BigQuery table and create the underlying jobs
# Reference for the full permission catalogue:
#   https://cloud.google.com/iam/docs/permissions-reference
resource "google_project_iam_custom_role" "log_read_only_analyst" {
  role_id     = "LogReadOnlyAnalyst"
  project     = var.project_id
  title       = "Log Read Only Analyst"
  description = "Read-only access to the logs bucket and the application_logs BigQuery table."
  stage       = "GA"
  permissions = [
    # Cloud Storage: metadata and object reads only.
    "storage.buckets.get",
    "storage.buckets.list",
    "storage.objects.get",
    "storage.objects.list",
    # BigQuery: read the table data and run query jobs.
    "bigquery.datasets.get",
    "bigquery.tables.get",
    "bigquery.tables.getData",
    "bigquery.tables.list",
    "bigquery.jobs.create",
    "bigquery.readsessions.create",
    "bigquery.readsessions.getData",
    "bigquery.readsessions.update",
  ]
}

# ----- Predefined-role bindings ----------------------------------------------

# Loader can read objects from the logs bucket.
resource "google_storage_bucket_iam_member" "loader_object_viewer" {
  bucket = google_storage_bucket.logs.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.loader.email}"
}

# Loader needs to append rows into the BigQuery table. dataEditor on the
# dataset and jobUser on the project together are the recommended pair for
# load jobs. Reference:
#   https://cloud.google.com/bigquery/docs/access-control
resource "google_bigquery_dataset_iam_member" "loader_data_editor" {
  dataset_id = google_bigquery_dataset.logs.dataset_id
  project    = var.project_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.loader.email}"
}

resource "google_project_iam_member" "loader_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.loader.email}"
}

# Loader writes its own logs.
resource "google_project_iam_member" "loader_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.loader.email}"
}

# ----- Analyst bindings ------------------------------------------------------

# Bind the custom role at the project scope to the analyst service account.
resource "google_project_iam_member" "analyst_custom_role" {
  project = var.project_id
  role    = google_project_iam_custom_role.log_read_only_analyst.id
  member  = "serviceAccount:${google_service_account.analyst.email}"
}

# Optional: bind the same custom role to a human principal (user or group) if
# the operator passes one in via terraform.tfvars.
resource "google_project_iam_member" "analyst_custom_role_human" {
  count   = var.analyst_principal == "" ? 0 : 1
  project = var.project_id
  role    = google_project_iam_custom_role.log_read_only_analyst.id
  member  = var.analyst_principal
}

# As an additional concrete example of binding a PREDEFINED role at resource
# scope, also grant the analyst the predefined BigQuery dataViewer role on the
# dataset. The custom role already covers the same permissions, but pairing
# them shows both styles, as the assignment requires.
resource "google_bigquery_dataset_iam_member" "analyst_data_viewer" {
  dataset_id = google_bigquery_dataset.logs.dataset_id
  project    = var.project_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.analyst.email}"
}

# ----- Eventarc plumbing -----------------------------------------------------
# The Cloud Storage service agent must be allowed to publish to Pub/Sub so
# Eventarc can deliver "object finalised" events. This is the exact role pair
# documented at:
#   https://cloud.google.com/eventarc/docs/run/quickstart-storage
resource "google_project_iam_member" "gcs_pubsub_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:service-${data.google_project.this.number}@gs-project-accounts.iam.gserviceaccount.com"

  depends_on = [google_project_service.enabled]
}

# Force the Eventarc Service Agent to be created right after the API is
# enabled. Without this, the first apply on a fresh project hits the
# 400 "Permission denied while using the Eventarc Service Agent" error
# because the agent is created lazily and Terraform tries to use it
# before propagation finishes. Reference:
#   https://cloud.google.com/eventarc/docs/eventarc-roles-permissions
resource "google_project_service_identity" "eventarc_agent" {
  provider = google-beta
  project  = var.project_id
  service  = "eventarc.googleapis.com"

  depends_on = [google_project_service.enabled]
}

# Belt and braces: bind the Eventarc Service Agent role explicitly. The role
# is granted automatically by Google, but doing it here makes the dependency
# graph deterministic for the time_sleep below.
resource "google_project_iam_member" "eventarc_service_agent" {
  project = var.project_id
  role    = "roles/eventarc.serviceAgent"
  member  = "serviceAccount:${google_project_service_identity.eventarc_agent.email}"
}

# Give IAM two minutes to propagate the binding before we try to create the
# Eventarc trigger. Empirically this is enough on cold projects.
resource "time_sleep" "wait_for_eventarc_agent" {
  depends_on      = [google_project_iam_member.eventarc_service_agent]
  create_duration = "120s"
}

# Loader needs to receive Eventarc events and invoke the underlying Cloud Run
# service that backs a Gen 2 Cloud Function.
resource "google_project_iam_member" "loader_eventarc_receiver" {
  project = var.project_id
  role    = "roles/eventarc.eventReceiver"
  member  = "serviceAccount:${google_service_account.loader.email}"
}

resource "google_project_iam_member" "loader_run_invoker" {
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${google_service_account.loader.email}"
}

resource "google_project_iam_member" "loader_artifact_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.loader.email}"
}
