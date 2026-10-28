#!/usr/bin/env bash
# =============================================================================
# CodeMender Enterprise FinOps: BigQuery External Table & Dashboard Views Setup
# =============================================================================
# Provisions a serverless BigQuery FinOps analytics layer directly over the
# append-only GCS telemetry bucket (`gs://<bucket>/codemender-finops-jsonl/*.jsonl`):
#   0. Runs pre-flight checks for CLI tools, active authentication, and required
#      operator IAM permissions.
#   1. Enables the BigQuery API (`bigquery.googleapis.com`).
#   2. Creates the `codemender_finops` BigQuery dataset.
#   3. Creates an External Table (`codemender_finops.scan_telemetry`) backed by
#      Newline-Delimited JSON (`.jsonl`) files in Cloud Storage — zero ETL required.
#   4. Creates two analytical Views for Looker Studio & FinOps chargeback:
#      - `v_repository_finops_summary`: Per-team/repository Gemini Enterprise
#        token, latency, vulnerability remediation, and estimated USD cost rollups.
#      - `v_command_bucket_breakdown`: Granular breakdown comparing `find` vs.
#        `fix` token consumption across repositories.
#
# Required Operator IAM Roles (on $PROJECT_ID and gs://$TELEMETRY_BUCKET):
#   - roles/serviceusage.serviceUsageAdmin       (Enable bigquery.googleapis.com, if needed)
#   - roles/bigquery.dataEditor                  (Or roles/bigquery.admin — create dataset/tables/views)
#   - roles/bigquery.jobUser                     (Run BigQuery DDL and analytical queries)
#   - roles/storage.objectViewer                 (Read gs://$TELEMETRY_BUCKET/codemender-finops-jsonl/*.jsonl)
#
# Usage:
#   export PROJECT_ID="codemender-latam"
#   export TELEMETRY_BUCKET="codemender-latam-codemender-telemetry"
#   ./scripts/setup-finops-bigquery.sh
# =============================================================================
set -euo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-codemender-latam}}"
TELEMETRY_BUCKET="${2:-${TELEMETRY_BUCKET:-${PROJECT_ID}-codemender-telemetry}}"
BQ_DATASET="${3:-${BQ_DATASET:-codemender_finops}}"
BQ_LOCATION="${4:-${BQ_LOCATION:-US}}"

echo "==> [0/4] Running Pre-Flight Operator & Permission Checks..."
for CMD in gcloud bq; do
  if ! command -v "${CMD}" >/dev/null 2>&1; then
    echo "ERROR: Required CLI tool '${CMD}' is not installed or not in PATH." >&2
    exit 1
  fi
done

ACTIVE_ACCOUNT=$(gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>/dev/null || true)
cat <<EOF
  Active Operator Identity : ${ACTIVE_ACCOUNT:-default-credentials}
  Target GCP Project       : ${PROJECT_ID}
  Target GCS Bucket        : gs://${TELEMETRY_BUCKET}
  Target BigQuery Dataset  : ${PROJECT_ID}:${BQ_DATASET} (${BQ_LOCATION})
  Required Operator Roles  :
    - roles/serviceusage.serviceUsageAdmin (if BigQuery API is not yet enabled)
    - roles/bigquery.dataEditor (or roles/bigquery.admin) + roles/bigquery.jobUser
    - roles/storage.objectViewer on gs://${TELEMETRY_BUCKET}
EOF

if ! bq ls --project_id="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "ERROR: Unable to access BigQuery on project '${PROJECT_ID}'." >&2
  echo "       Verify that your credentials are active ('gcloud auth login') and that your" >&2
  echo "       principal holds roles/bigquery.jobUser and roles/bigquery.dataEditor on '${PROJECT_ID}'." >&2
  exit 1
fi
echo "  Pre-flight check passed."

echo "==> [1/4] Enabling BigQuery API on ${PROJECT_ID}..."
gcloud services enable bigquery.googleapis.com --project="${PROJECT_ID}" >/dev/null 2>&1 || true

echo "==> [2/4] Creating BigQuery Dataset ${PROJECT_ID}:${BQ_DATASET} (${BQ_LOCATION})..."
if ! bq --project_id="${PROJECT_ID}" show --dataset "${PROJECT_ID}:${BQ_DATASET}" >/dev/null 2>&1; then
  bq --location="${BQ_LOCATION}" --project_id="${PROJECT_ID}" mk \
    --dataset \
    --description="CodeMender Enterprise DevSecOps & Gemini Enterprise FinOps Telemetry" \
    "${PROJECT_ID}:${BQ_DATASET}"
fi

echo "==> [3/4] Creating BigQuery External Table ${PROJECT_ID}.${BQ_DATASET}.scan_telemetry..."
bq --location="${BQ_LOCATION}" --project_id="${PROJECT_ID}" query --use_legacy_sql=false <<EOF
CREATE OR REPLACE EXTERNAL TABLE \`${PROJECT_ID}.${BQ_DATASET}.scan_telemetry\` (
  event_timestamp TIMESTAMP,
  scan_date DATE,
  gcp_project_id STRING,
  repository STRING,
  repository_owner STRING,
  repository_name STRING,
  scan_mode STRING,
  scan_path STRING,
  github_run_id INT64,
  github_event_name STRING,
  git_ref STRING,
  git_sha STRING,
  total_open_findings INT64,
  target_findings INT64,
  fixed_findings INT64,
  autofix_enabled BOOL,
  since STRING,
  total_turns INT64,
  total_polls INT64,
  command_types INT64,
  input_tokens INT64,
  output_tokens INT64,
  cached_tokens INT64,
  thought_tokens INT64,
  tool_calls INT64,
  total_tokens INT64,
  cache_hit_percent FLOAT64,
  think_ratio_percent FLOAT64,
  duration_seconds FLOAT64,
  duration_formatted STRING,
  buckets ARRAY<STRUCT<
    label STRING,
    requests INT64,
    polls INT64,
    input_tokens INT64,
    output_tokens INT64,
    cached_tokens INT64,
    thought_tokens INT64,
    tool_calls INT64,
    total_tokens INT64,
    cache_hit_percent FLOAT64,
    think_ratio_percent FLOAT64,
    duration_seconds FLOAT64,
    duration_formatted STRING
  >>
)
OPTIONS (
  format = 'NEWLINE_DELIMITED_JSON',
  uris = ['gs://${TELEMETRY_BUCKET}/codemender-finops-jsonl/*.jsonl'],
  ignore_unknown_values = TRUE
);
EOF

echo "==> [4/4] Creating FinOps Executive Views (${BQ_DATASET}.v_repository_finops_summary & v_command_bucket_breakdown)..."
bq --location="${BQ_LOCATION}" --project_id="${PROJECT_ID}" query --use_legacy_sql=false <<EOF
CREATE OR REPLACE VIEW \`${PROJECT_ID}.${BQ_DATASET}.v_repository_finops_summary\` AS
SELECT
  repository,
  repository_name,
  scan_mode,
  COUNT(DISTINCT github_run_id) AS total_scans,
  MAX(event_timestamp) AS last_scan_utc,
  SUM(total_open_findings) AS total_findings_detected,
  SUM(fixed_findings) AS total_findings_remediated,
  SUM(input_tokens) AS total_input_tokens,
  SUM(cached_tokens) AS total_cached_tokens,
  SUM(output_tokens) AS total_output_tokens,
  SUM(thought_tokens) AS total_thought_tokens,
  SUM(total_tokens) AS total_tokens,
  ROUND(AVG(cache_hit_percent), 2) AS avg_cache_hit_pct,
  ROUND(SUM(duration_seconds), 1) AS total_duration_sec,
  ROUND(
    (SUM(GREATEST(input_tokens - cached_tokens, 0)) / 1000000.0 * 1.25) +
    (SUM(cached_tokens) / 1000000.0 * 0.3125) +
    (SUM(output_tokens + thought_tokens) / 1000000.0 * 10.00),
    4
  ) AS estimated_cost_usd
FROM \`${PROJECT_ID}.${BQ_DATASET}.scan_telemetry\`
GROUP BY repository, repository_name, scan_mode
ORDER BY total_tokens DESC;

CREATE OR REPLACE VIEW \`${PROJECT_ID}.${BQ_DATASET}.v_command_bucket_breakdown\` AS
SELECT
  t.event_timestamp,
  t.repository,
  t.scan_mode,
  t.github_run_id,
  b.label AS command_bucket,
  b.requests,
  b.input_tokens,
  b.cached_tokens,
  b.output_tokens,
  b.thought_tokens,
  b.total_tokens,
  ROUND(b.cache_hit_percent, 2) AS cache_hit_pct,
  b.duration_seconds,
  b.duration_formatted
FROM \`${PROJECT_ID}.${BQ_DATASET}.scan_telemetry\` AS t,
UNNEST(t.buckets) AS b
WHERE b.label != 'total'
ORDER BY t.event_timestamp DESC, b.total_tokens DESC;
EOF

echo ""
echo "============================================================================="
echo " BigQuery FinOps Analytics Provisioned Successfully!"
echo "============================================================================="
echo "External Table : ${PROJECT_ID}.${BQ_DATASET}.scan_telemetry"
echo "Summary View   : ${PROJECT_ID}.${BQ_DATASET}.v_repository_finops_summary"
echo "Breakdown View : ${PROJECT_ID}.${BQ_DATASET}.v_command_bucket_breakdown"
echo ""
echo "Sample Query:"
echo "  bq query --project_id=${PROJECT_ID} --use_legacy_sql=false \\"
echo "    'SELECT * FROM \`${PROJECT_ID}.${BQ_DATASET}.v_repository_finops_summary\`'"
echo "============================================================================="
