###############################################################################
# bigquery.tf
# Dataset and table for the ingested logs.
#
# Design choices:
#   * Dataset location is the same region as the bucket. BigQuery cannot load
#     across incompatible regions for managed jobs, and co-locating is also
#     the lowest cost option. Reference:
#     https://cloud.google.com/bigquery/docs/locations
#   * default_table_expiration_ms enforces a hard ceiling on table age so the
#     dataset cannot silently grow past the 10 GB Free Tier quota.
#   * The table is time-partitioned on event_timestamp (DAY granularity) and
#     clustered on severity and service. Partition pruning is what keeps the
#     1 TiB monthly query Free Tier comfortable: a single-day query reads a
#     single-day partition. Reference:
#     https://cloud.google.com/bigquery/docs/partitioned-tables
#   * require_partition_filter = true forces every query to include a
#     predicate on event_timestamp. This is a Free Tier guardrail.
###############################################################################

resource "google_bigquery_dataset" "logs" {
  dataset_id                  = replace("${var.name_prefix}_logs", "-", "_")
  project                     = var.project_id
  location                    = var.region
  description                 = "Application logs ingested from Cloud Storage."
  default_table_expiration_ms = var.bigquery_table_expiration_ms
  delete_contents_on_destroy  = true

  labels = {
    purpose = "application-logs"
    env     = "lab"
  }

  depends_on = [google_project_service.enabled]
}

resource "google_bigquery_table" "application_logs" {
  dataset_id          = google_bigquery_dataset.logs.dataset_id
  table_id            = "application_logs"
  project             = var.project_id
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "event_timestamp"
  }

  # Force every query to include a predicate on event_timestamp so partition
  # pruning keeps the bytes scanned, and therefore the Free Tier consumption,
  # under control. (Top-level argument is the supported location since the
  # provider deprecated the nested form.)
  require_partition_filter = true

  clustering = ["severity", "service"]

  schema = jsonencode([
    {
      name        = "event_timestamp"
      type        = "TIMESTAMP"
      mode        = "REQUIRED"
      description = "UTC timestamp of the event."
    },
    {
      name        = "severity"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "DEBUG, INFO, WARNING, ERROR or CRITICAL."
    },
    {
      name        = "service"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Logical service name."
    },
    {
      name        = "host"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Hostname or pod that produced the event."
    },
    {
      name        = "message"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Free-form log line."
    },
    {
      name        = "user_id"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Authenticated user, when applicable."
    },
    {
      name        = "latency_ms"
      type        = "INT64"
      mode        = "NULLABLE"
      description = "Request latency in milliseconds."
    },
    {
      name        = "http_status"
      type        = "INT64"
      mode        = "NULLABLE"
      description = "HTTP response code, when the event is an HTTP call."
    },
    {
      name        = "source_path"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Endpoint or code path that emitted the event."
    },
  ])

  labels = {
    purpose = "application-logs"
    env     = "lab"
  }
}
