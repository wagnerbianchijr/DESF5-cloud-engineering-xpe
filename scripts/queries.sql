-- Analytical queries for the application_logs table.
-- Every query includes an event_timestamp predicate so partition pruning
-- keeps bytes scanned, and therefore the Free Tier consumption, minimal.
-- Replace {project} and {dataset} placeholders before execution, or use the
-- bq command: bq query --use_legacy_sql=false < queries.sql
--
-- Reference (partitioned tables):
--   https://cloud.google.com/bigquery/docs/querying-partitioned-tables

-- 1. First 10 records (most recent first).
SELECT
  event_timestamp,
  severity,
  service,
  http_status,
  latency_ms,
  message
FROM `{project}.{dataset}.application_logs`
WHERE event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
ORDER BY event_timestamp DESC
LIMIT 10;

-- 2. Total row count for the last 30 days.
SELECT COUNT(*) AS total_rows
FROM `{project}.{dataset}.application_logs`
WHERE event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY);

-- 3. Severity distribution.
SELECT
  severity,
  COUNT(*) AS events,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM `{project}.{dataset}.application_logs`
WHERE event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
GROUP BY severity
ORDER BY events DESC;

-- 4. Average and 95th percentile latency by service.
SELECT
  service,
  COUNT(*) AS events,
  ROUND(AVG(latency_ms), 1) AS avg_latency_ms,
  APPROX_QUANTILES(latency_ms, 100)[OFFSET(95)] AS p95_latency_ms
FROM `{project}.{dataset}.application_logs`
WHERE event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
  AND latency_ms IS NOT NULL
GROUP BY service
ORDER BY p95_latency_ms DESC;

-- 5. Error rate per hour (5xx responses) for the busiest service.
WITH busiest AS (
  SELECT service
  FROM `{project}.{dataset}.application_logs`
  WHERE event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
  GROUP BY service
  ORDER BY COUNT(*) DESC
  LIMIT 1
)
SELECT
  TIMESTAMP_TRUNC(event_timestamp, HOUR) AS hour,
  COUNTIF(http_status BETWEEN 500 AND 599) AS errors,
  COUNT(*) AS total,
  SAFE_DIVIDE(COUNTIF(http_status BETWEEN 500 AND 599), COUNT(*)) AS error_rate
FROM `{project}.{dataset}.application_logs`
WHERE event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
  AND service IN (SELECT service FROM busiest)
GROUP BY hour
ORDER BY hour DESC
LIMIT 24;
