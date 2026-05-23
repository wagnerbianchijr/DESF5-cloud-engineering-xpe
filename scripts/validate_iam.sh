#!/usr/bin/env bash
# validate_iam.sh
# Acts as the analyst service account and proves that:
#   * It CAN list the logs bucket and run a SELECT against the table.
#   * It CANNOT delete a bucket or run an INSERT statement.
#
# Prerequisites:
#   * gcloud and bq installed and authenticated as a Project Owner.
#   * Terraform applied. Outputs are read via `terraform output -raw`.
#
# Usage:
#   cd terraform && terraform output  # confirm outputs exist
#   ../scripts/validate_iam.sh

set -uo pipefail

cd "$(dirname "$0")/../terraform"

PROJECT_ID="$(terraform output -raw bigquery_table | cut -d. -f1)"
DATASET="$(terraform output -raw bigquery_dataset)"
TABLE="$(terraform output -raw bigquery_table)"
BUCKET="$(terraform output -raw logs_bucket)"
ANALYST_SA="$(terraform output -raw analyst_service_account)"

KEY_FILE="$(mktemp -t analyst-key-XXXXXX.json)"
trap 'rm -f "${KEY_FILE}"' EXIT

echo ">> Minting a short-lived key for ${ANALYST_SA}"
gcloud iam service-accounts keys create "${KEY_FILE}" \
  --iam-account "${ANALYST_SA}" \
  --project "${PROJECT_ID}"

echo ">> Activating analyst credentials"
gcloud auth activate-service-account --key-file "${KEY_FILE}"
gcloud config set project "${PROJECT_ID}" >/dev/null

pass() { printf "  [PASS] %s\n" "$1"; }
fail() { printf "  [FAIL] %s\n" "$1"; }

echo ">> Permitted: list bucket"
if gsutil ls -b "gs://${BUCKET}" >/dev/null 2>&1; then pass "list bucket"; else fail "list bucket"; fi

echo ">> Permitted: read a few rows from the table"
if bq --project_id="${PROJECT_ID}" query --use_legacy_sql=false --max_rows=3 \
   "SELECT severity, COUNT(*) AS n FROM \`${TABLE}\` WHERE event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY) GROUP BY severity" >/dev/null 2>&1; then
  pass "SELECT against application_logs"
else
  fail "SELECT against application_logs"
fi

echo ">> Forbidden: attempt to delete the bucket"
if gsutil rb "gs://${BUCKET}" >/dev/null 2>&1; then
  fail "bucket deletion succeeded (it should have been denied)"
else
  pass "bucket deletion was denied as expected"
fi

echo ">> Forbidden: attempt to insert a row"
if bq --project_id="${PROJECT_ID}" query --use_legacy_sql=false \
   "INSERT INTO \`${TABLE}\` (event_timestamp, severity, service) VALUES (CURRENT_TIMESTAMP(), 'INFO', 'test')" >/dev/null 2>&1; then
  fail "INSERT succeeded (it should have been denied)"
else
  pass "INSERT was denied as expected"
fi

echo
echo "Done. Re-authenticate to your own account with:"
echo "  gcloud auth login"
