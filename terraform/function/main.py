"""Cloud Function: load a newly finalised GCS NDJSON object into BigQuery.

The function is invoked by Eventarc whenever the configured bucket emits a
google.cloud.storage.object.v1.finalized event. It expects newline delimited
JSON whose keys match the application_logs schema declared in bigquery.tf.

Environment variables (injected by Terraform):
    BQ_PROJECT  Project that owns the dataset.
    BQ_DATASET  Dataset ID.
    BQ_TABLE    Destination table ID.

The function is idempotent at the load-job level: BigQuery rejects duplicate
job IDs, so retrying the same event will not produce double rows.
"""

from __future__ import annotations

import logging
import os
import re

import functions_framework
from cloudevents.http import CloudEvent
from google.cloud import bigquery

LOG = logging.getLogger(__name__)
LOG.setLevel(logging.INFO)

_LOAD_EXTENSIONS = (".ndjson", ".jsonl", ".json")
_SAFE_JOB_ID = re.compile(r"[^a-zA-Z0-9_-]")


def _job_id_for(bucket: str, name: str, generation: str) -> str:
    """Build a stable, BigQuery-safe job ID from the event coordinates."""
    raw = f"load-{bucket}-{name}-{generation}"
    return _SAFE_JOB_ID.sub("_", raw)[:1024]


@functions_framework.cloud_event
def load_to_bigquery(event: CloudEvent) -> None:
    data = event.data or {}
    bucket = data.get("bucket")
    name = data.get("name")
    generation = str(data.get("generation", ""))

    if not bucket or not name:
        LOG.warning("Event payload missing bucket or name. Skipping. payload=%s", data)
        return

    if not name.lower().endswith(_LOAD_EXTENSIONS):
        LOG.info("Skipping %s/%s: not an NDJSON file.", bucket, name)
        return

    project = os.environ["BQ_PROJECT"]
    dataset = os.environ["BQ_DATASET"]
    table = os.environ["BQ_TABLE"]
    table_ref = f"{project}.{dataset}.{table}"
    uri = f"gs://{bucket}/{name}"

    LOG.info("Loading %s into %s", uri, table_ref)

    client = bigquery.Client(project=project)
    job_config = bigquery.LoadJobConfig(
        source_format=bigquery.SourceFormat.NEWLINE_DELIMITED_JSON,
        write_disposition=bigquery.WriteDisposition.WRITE_APPEND,
        create_disposition=bigquery.CreateDisposition.CREATE_NEVER,
        ignore_unknown_values=False,
        max_bad_records=0,
        time_partitioning=bigquery.TimePartitioning(
            type_=bigquery.TimePartitioningType.DAY,
            field="event_timestamp",
        ),
        # The destination table is clustered on (severity, service). When the
        # table is clustered, the load job config must declare the same
        # clustering fields, otherwise BigQuery rejects it with
        # "Incompatible table partitioning specification". Reference:
        #   https://cloud.google.com/bigquery/docs/clustered-tables
        clustering_fields=["severity", "service"],
    )

    job = client.load_table_from_uri(
        uri,
        table_ref,
        job_id=_job_id_for(bucket, name, generation),
        job_config=job_config,
    )
    result = job.result()  # Block until the load completes or raises.
    LOG.info(
        "Loaded %s rows from %s into %s (state=%s).",
        result.output_rows,
        uri,
        table_ref,
        job.state,
    )
