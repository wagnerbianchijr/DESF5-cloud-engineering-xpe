# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project shape

A single Terraform module (this directory) provisions an end-to-end log analytics pipeline on GCP:

Cloud Storage (NDJSON drop bucket) → Eventarc `object.finalized` → Gen 2 Cloud Function (`function/main.py`) → BigQuery `application_logs` table (day-partitioned, clustered).

The deliverable is intentionally "one `terraform apply` away". The parent repo (`../`) holds the sample data (`data/sample_logs.ndjson`), helper scripts (`scripts/`), and the rendered architecture diagram (`docs/`).

## Common commands

```bash
# From this directory (terraform/):
terraform init
terraform plan
terraform apply
terraform destroy

# Regenerate the synthetic NDJSON (5000 rows, seeded for determinism)
python3 ../scripts/generate_logs.py --rows 5000 --out ../data/sample_logs.ndjson

# Prove the analyst SA is read-only (reads `terraform output` for resource names)
../scripts/validate_iam.sh
```

Authentication is via Application Default Credentials — run `gcloud auth application-default login` and `gcloud config set project YOUR_PROJECT_ID` before applying. Copy `terraform.tfvars.example` to `terraform.tfvars` and set `project_id`.

## Architecture details that span multiple files

**Free Tier guardrails are load-bearing — do not remove them casually.** They are enforced in three places that must stay aligned:
- `variables.tf` — `region` has a `validation` block restricting to `us-east1`/`us-west1`/`us-central1` (Cloud Storage Always Free regions).
- `storage.tf` — `public_access_prevention = "enforced"`, `uniform_bucket_level_access = true`, lifecycle rules transition to NEARLINE after 30d and delete after 365d.
- `bigquery.tf` — `require_partition_filter = true` on the table forces every query to include an `event_timestamp` predicate, and `default_table_expiration_ms` on the dataset caps storage. Any query (including in `../scripts/queries.sql`) must include that predicate or BigQuery rejects it.

**Eventarc bootstrap is order-sensitive.** Fresh projects fail on first apply because the Eventarc Service Agent is created lazily. `iam.tf` works around this with three resources that must stay together:
1. `google_project_service_identity.eventarc_agent` (forces the agent into existence via `google-beta`).
2. `google_project_iam_member.eventarc_service_agent` (explicit `roles/eventarc.serviceAgent` binding).
3. `time_sleep.wait_for_eventarc_agent` (120s for IAM propagation; the function `depends_on` it).

Similarly, the GCS service agent needs `roles/pubsub.publisher` for Eventarc to deliver bucket events — bound at `iam.tf` via `service-${project_number}@gs-project-accounts.iam.gserviceaccount.com`.

**Two service accounts, one custom role.** The assignment requires both predefined and custom IAM:
- `sa-loader` — workload identity for the Cloud Function. Bound at narrowest scope: `objectViewer` on the logs bucket, `dataEditor` on the dataset, `jobUser`/`logWriter`/`eventReceiver`/`run.invoker`/`artifactregistry.reader` at project scope.
- `sa-analyst` — read-only consumer. Bound to the custom role `LogReadOnlyAnalyst` (defined in `iam.tf`) at project scope, plus the predefined `bigquery.dataViewer` on the dataset (pair shown deliberately for the assignment).
- Optional human principal via `var.analyst_principal` (format: `user:email` or `group:email`).

**Two buckets, separated on purpose.** `logs` (NDJSON drop, versioned, lifecycle rules) and `function_source` (zipped function code, `force_destroy = true`). Keeping them separate prevents the loader from triggering itself when its own source is uploaded.

**Function source zipping is automatic.** `data.archive_file.function_source` zips `function/` into `.build/function.zip` on every apply; the object name uses `output_md5` so changes redeploy automatically. Edits to `function/main.py` or `function/requirements.txt` ship on the next `terraform apply` with no manual zip step.

**Loader function is idempotent.** `function/main.py` builds a deterministic job ID from `bucket+name+generation`, so retries don't double-load. It also filters to `.ndjson`/`.jsonl`/`.json` suffixes and uses `CREATE_NEVER` + `WRITE_APPEND` so the table must already exist (it does — Terraform creates it).

**Seed object depends on the function.** `google_storage_bucket_object.sample_logs` has `depends_on = [google_cloudfunctions2_function.loader]` so the first Eventarc event isn't lost during a cold apply.

## Things to know before editing

- Provider pins are in `versions.tf` (`google` and `google-beta` `~> 6.10`). The `google-beta` provider is only used for `google_project_service_identity` — keep it that way.
- BigQuery dataset ID replaces hyphens with underscores (`replace("${var.name_prefix}_logs", "-", "_")`) because BQ identifiers reject hyphens.
- Bucket names use a `random_id` suffix (`local.suffix`) for global uniqueness across re-applies.
- `terraform.tfvars` and `*.json` keys are gitignored (see `../.gitignore`). The validate script mints a short-lived analyst key and cleans it up via `trap`.
- `bucket_force_destroy = true` is the lab default — set to `false` if a destroy needs to preserve evidence.
