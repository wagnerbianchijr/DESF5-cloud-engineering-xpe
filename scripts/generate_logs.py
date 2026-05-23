#!/usr/bin/env python3
"""Generate a deterministic NDJSON file of synthetic application logs.

The output file is loaded into Cloud Storage by Terraform and ingested by the
Cloud Function into BigQuery. Each line is a single JSON object whose keys
match the BigQuery table schema declared in bigquery.tf.

Usage:
    python3 generate_logs.py --rows 5000 --out ../data/sample_logs.ndjson
"""

from __future__ import annotations

import argparse
import json
import random
from datetime import datetime, timedelta, timezone
from pathlib import Path

SEVERITIES = ["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"]
SEVERITY_WEIGHTS = [10, 60, 18, 10, 2]
SERVICES = ["auth", "billing", "catalog", "checkout", "ingest", "search", "notifications"]
HOSTS = [f"host-{i:02d}" for i in range(1, 13)]
HTTP_STATUS = [200, 201, 204, 301, 400, 401, 403, 404, 422, 500, 502, 503]
HTTP_STATUS_WEIGHTS = [55, 6, 4, 3, 8, 4, 3, 6, 3, 4, 2, 2]
PATHS = [
    "/api/v1/users",
    "/api/v1/orders",
    "/api/v1/products",
    "/api/v1/sessions",
    "/api/v1/events",
    "/healthz",
    "/metrics",
]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rows", type=int, default=5000)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    rng = random.Random(args.seed)
    now = datetime.now(tz=timezone.utc)

    args.out.parent.mkdir(parents=True, exist_ok=True)

    with args.out.open("w", encoding="utf-8") as handle:
        for i in range(args.rows):
            ts = now - timedelta(seconds=rng.randint(0, 30 * 24 * 3600))
            severity = rng.choices(SEVERITIES, weights=SEVERITY_WEIGHTS, k=1)[0]
            service = rng.choice(SERVICES)
            host = rng.choice(HOSTS)
            status = rng.choices(HTTP_STATUS, weights=HTTP_STATUS_WEIGHTS, k=1)[0]
            latency = max(1, int(rng.gauss(120, 80)))
            user_id = f"user_{rng.randint(1, 9999):04d}" if rng.random() > 0.05 else None

            record = {
                "event_timestamp": ts.isoformat(timespec="microseconds").replace("+00:00", "Z"),
                "severity": severity,
                "service": service,
                "host": host,
                "message": f"{service}: handled request with status {status}",
                "user_id": user_id,
                "latency_ms": latency,
                "http_status": status,
                "source_path": rng.choice(PATHS),
            }
            handle.write(json.dumps(record, separators=(",", ":")) + "\n")

    print(f"Wrote {args.rows} rows to {args.out}")


if __name__ == "__main__":
    main()
