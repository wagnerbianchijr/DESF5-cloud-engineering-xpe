# Desafio Final - Engenheiro Cloud

End to end log analytics pipeline on Google Cloud, provisioned with Terraform.
The deliverable answers the four activities of the assignment and stays
inside the Always Free quota.

## Architecture in one sentence

Applications drop NDJSON log files into a regional Cloud Storage bucket, an
Eventarc trigger wakes a Gen 2 Cloud Function, the function streams the rows
into a partitioned BigQuery table, and two service accounts (loader and
analyst) plus a custom IAM role enforce least-privilege access.

![Architecture diagram](docs/architecture.svg)

## Repository layout

```
desafio-final-gcp/
  terraform/              # Terraform module (the only thing you apply)
    versions.tf           # CLI and provider pins
    providers.tf          # google + google-beta wiring
    variables.tf          # All inputs
    main.tf               # APIs to enable + suffix + project lookup
    storage.tf            # Bucket, lifecycle, sample object
    bigquery.tf           # Dataset and partitioned/clustered table
    iam.tf                # Service accounts, predefined and custom roles
    function.tf           # Gen 2 function + Eventarc trigger
    function/             # Python source of the loader
    terraform.tfvars.example
  data/
    sample_logs.ndjson    # 5000 synthetic log rows generated for the lab
  scripts/
    generate_logs.py      # Re-generates the NDJSON file
    queries.sql           # Five analytical queries (use partition filters)
    validate_iam.sh       # Proves analyst SA cannot mutate resources
  docs/
    architecture.svg      # Diagram embedded above
```

## How to apply

The work is deliberately one `terraform apply` away.

```bash
# 1. Authenticate (sets Application Default Credentials)
gcloud auth application-default login
gcloud config set project YOUR_PROJECT_ID

# 2. Configure inputs
cd terraform
cp terraform.tfvars.example terraform.tfvars
${EDITOR:-vi} terraform.tfvars

# 3. Initialise and apply
terraform init
terraform plan
terraform apply
```

After apply, the outputs print the bucket name, dataset, table, and both
service account emails. The seed file `data/sample_logs.ndjson` is uploaded
automatically and triggers the loader on the first run.

## Free Tier guardrails baked into the code

Cloud Storage Always Free quotas: 5 GB-month, 5,000 Class A, 50,000 Class B,
100 GB North America egress
([reference](https://cloud.google.com/free/docs/free-cloud-features#storage)).
The module enforces them with:

- Region restricted to `us-central1` / `us-east1` / `us-west1` by a `validation`
  block on `var.region`.
- Lifecycle rule transitions cold objects to NEARLINE after 30 days and deletes
  them after 365, keeping the resident footprint inside 5 GB.
- `public_access_prevention = "enforced"` blocks any accidental anonymous
  egress, the line item most likely to blow the 100 GB egress quota.

BigQuery Always Free quotas: 1 TiB on-demand queries and 10 GB active storage
per month
([reference](https://cloud.google.com/bigquery/pricing#free-tier)). The module
enforces them with:

- `default_table_expiration_ms` on the dataset, so any future table also
  inherits a 365 day cap.
- `require_partition_filter = true` on the table: every query must include an
  `event_timestamp` predicate, otherwise BigQuery rejects it.
- DAY partitioning plus clustering on `severity` and `service`, so a typical
  query scans a handful of MB.

## IAM model

The assignment requires both predefined and custom roles. The module emits
both.

| Principal | Role | Scope | Why |
| --- | --- | --- | --- |
| `sa-loader` | `roles/storage.objectViewer` | Bucket | Read NDJSON objects to load. |
| `sa-loader` | `roles/bigquery.dataEditor` | Dataset | Append rows into `application_logs`. |
| `sa-loader` | `roles/bigquery.jobUser` | Project | Run load jobs. |
| `sa-loader` | `roles/eventarc.eventReceiver` | Project | Receive Eventarc deliveries. |
| `sa-loader` | `roles/run.invoker` | Project | Invoke the underlying Cloud Run service of the Gen 2 function. |
| `sa-loader` | `roles/artifactregistry.reader` | Project | Pull the built container image. |
| `sa-loader` | `roles/logging.logWriter` | Project | Emit structured logs from the function. |
| `sa-analyst` | `projects/{p}/roles/LogReadOnlyAnalyst` | Project | The custom role required by Atividade 1. |
| `sa-analyst` | `roles/bigquery.dataViewer` | Dataset | A predefined complement, shown for comparison. |
| Cloud Storage agent | `roles/pubsub.publisher` | Project | Mandatory for Eventarc GCS triggers ([source](https://cloud.google.com/eventarc/docs/run/quickstart-storage)). |

`LogReadOnlyAnalyst` is built from atomic permissions taken from the
[permissions reference](https://cloud.google.com/iam/docs/permissions-reference)
and grants read on bucket metadata, read on objects, read on the BigQuery
table, and the ability to run query jobs. No write, no delete, no admin.

## Sample analytical queries

`scripts/queries.sql` includes:

1. The 10 most recent rows.
2. Total row count for the last 30 days.
3. Severity distribution with percentages.
4. Average and p95 latency by service for the last 7 days.
5. Hourly error rate (5xx) for the busiest service.

All queries include an `event_timestamp` predicate, so partition pruning
keeps bytes scanned in the kilobytes range.

## Validating IAM works

After apply:

```bash
./scripts/validate_iam.sh
```

The script mints a short-lived key for the analyst service account, then
proves two things:

- The analyst CAN list the bucket and run a `SELECT` against the table.
- The analyst CANNOT delete the bucket or run an `INSERT`. Both attempts come
  back with `PERMISSION_DENIED`, which is exactly what we want.

## Cleaning up

`terraform destroy` removes everything, including the bucket
(`force_destroy = true` by default for the lab). If you want to keep the
bucket as evidence, set `bucket_force_destroy = false` before destroy.

## Authoritative references

- Google Cloud Free Tier: https://cloud.google.com/free/docs/free-cloud-features
- Cloud Storage Free Tier limits: https://cloud.google.com/free/docs/free-cloud-features#storage
- BigQuery Free Tier limits: https://cloud.google.com/bigquery/pricing#free-tier
- Lifecycle Management: https://cloud.google.com/storage/docs/lifecycle
- BigQuery partitioned tables: https://cloud.google.com/bigquery/docs/partitioned-tables
- Eventarc with Cloud Storage: https://cloud.google.com/eventarc/docs/run/quickstart-storage
- IAM custom roles: https://cloud.google.com/iam/docs/creating-custom-roles
- Cloud Functions Gen 2: https://cloud.google.com/functions/docs/2nd-gen/overview
- Terraform Google provider: https://registry.terraform.io/providers/hashicorp/google/latest/docs

## Compliance note for the writer

PostgreSQL with TimescaleDB on Tiger Cloud is my preferred home for
time-series workloads of this shape. For this exercise the assignment
mandates Cloud Storage plus BigQuery on GCP, so the architecture lives there.
The same NDJSON ingestion pattern would map cleanly onto TimescaleDB
hypertables on Tiger Cloud should the requirements change.
