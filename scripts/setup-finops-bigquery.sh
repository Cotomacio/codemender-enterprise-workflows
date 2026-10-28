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
  event_timestamp TIMESTAMP OPTIONS(description="UTC timestamp when the CodeMender CI/CD workflow completed and exported telemetry."),
  scan_date DATE OPTIONS(description="UTC calendar date of the CodeMender scan run."),
  gcp_project_id STRING OPTIONS(description="Google Cloud project ID hosting Gemini Enterprise and CodeMender API quota."),
  repository STRING OPTIONS(description="Full GitHub repository identifier in 'owner/repo' format (e.g., 'Cotomacio/team-a-payments')."),
  repository_owner STRING OPTIONS(description="GitHub Organization or user owner name."),
  repository_name STRING OPTIONS(description="Short GitHub repository name without owner prefix (e.g., 'team-a-payments')."),
  scan_mode STRING OPTIONS(description="CodeMender scan mode: 'deep' (full repository audit), 'diff' (PR delta + 1-hop callers), or 'quick'."),
  scan_path STRING OPTIONS(description="Relative directory path scanned within the repository (default '.')."),
  github_run_id INT64 OPTIONS(description="Unique GitHub Actions workflow run ID (primary key per execution)."),
  github_event_name STRING OPTIONS(description="GitHub event that triggered the workflow ('schedule', 'pull_request', 'workflow_dispatch')."),
  git_ref STRING OPTIONS(description="Git branch or tag reference scanned (e.g., 'main')."),
  git_sha STRING OPTIONS(description="40-character Git commit SHA scanned."),
  total_open_findings INT64 OPTIONS(description="Total number of OPEN security vulnerabilities detected by CodeMender in this run across all severities."),
  target_findings INT64 OPTIONS(description="Number of OPEN vulnerabilities matching target fix_severities (e.g., CRITICAL,HIGH) eligible for auto-remediation."),
  fixed_findings INT64 OPTIONS(description="Number of vulnerabilities autonomously patched, verified, and committed by 'cm fix' during this run."),
  autofix_enabled BOOL OPTIONS(description="Whether autonomous remediation ('cm fix') was enabled for this workflow run."),
  since STRING OPTIONS(description="Start timestamp of local CodeMender CLI telemetry tracking."),
  total_turns INT64 OPTIONS(description="Total Gemini Enterprise conversational turns across all commands in this run."),
  total_polls INT64 OPTIONS(description="Total asynchronous API polling requests during the run."),
  command_types INT64 OPTIONS(description="Number of distinct CodeMender CLI command types executed (e.g., 2 when both 'find' and 'fix' run)."),
  input_tokens INT64 OPTIONS(description="Total Gemini Enterprise input tokens consumed in this run. IMPORTANT: input_tokens ALREADY INCLUDES cached_tokens. Uncached input tokens = GREATEST(input_tokens - cached_tokens, 0)."),
  output_tokens INT64 OPTIONS(description="Total Gemini Enterprise generated output tokens (excluding thought_tokens)."),
  cached_tokens INT64 OPTIONS(description="Subset of input_tokens served from Gemini Enterprise Context Cache at a 75% discount ($0.3125/1M vs $1.25/1M uncached)."),
  thought_tokens INT64 OPTIONS(description="Total Gemini Enterprise internal reasoning/thinking tokens consumed during vulnerability analysis and patch verification."),
  tool_calls INT64 OPTIONS(description="Total agentic tool invocations executed by CodeMender during analysis and patching."),
  total_tokens INT64 OPTIONS(description="Total tokens consumed in the run (input_tokens + output_tokens + thought_tokens). Do NOT add cached_tokens to this sum."),
  cache_hit_percent FLOAT64 OPTIONS(description="Percentage of input_tokens served from Gemini Enterprise Context Cache (cached_tokens / input_tokens * 100)."),
  think_ratio_percent FLOAT64 OPTIONS(description="Percentage of completion tokens spent on internal reasoning/thought."),
  duration_seconds FLOAT64 OPTIONS(description="Total active CodeMender CLI execution time in seconds across find and fix phases."),
  duration_formatted STRING OPTIONS(description="Human-readable active execution duration (e.g., '15m 46s')."),
  buckets ARRAY<STRUCT<
    label STRING OPTIONS(description="CLI command bucket label (e.g., 'find --deep', 'find --diff', 'fix', or 'total'). IMPORTANT: Always filter WHERE label != 'total' when unnesting buckets to avoid 2x double-counting."),
    requests INT64 OPTIONS(description="Number of CLI command invocations in this bucket (e.g., 1 for 'find --deep', or N for 'fix' where N findings were patched)."),
    polls INT64 OPTIONS(description="Polling count for this command bucket."),
    input_tokens INT64 OPTIONS(description="Total input tokens for this command bucket (includes cached_tokens)."),
    output_tokens INT64 OPTIONS(description="Generated output tokens for this command bucket."),
    cached_tokens INT64 OPTIONS(description="Subset of input_tokens served from Context Cache for this command bucket."),
    thought_tokens INT64 OPTIONS(description="Internal reasoning tokens for this command bucket."),
    tool_calls INT64 OPTIONS(description="Agentic tool calls executed within this command bucket."),
    total_tokens INT64 OPTIONS(description="Total tokens (input_tokens + output_tokens + thought_tokens) for this command bucket."),
    cache_hit_percent FLOAT64 OPTIONS(description="Context cache hit rate percentage for this command bucket."),
    think_ratio_percent FLOAT64 OPTIONS(description="Reasoning token ratio percentage for this command bucket."),
    duration_seconds FLOAT64 OPTIONS(description="Execution duration in seconds for this command bucket."),
    duration_formatted STRING OPTIONS(description="Human-readable duration for this command bucket (e.g., '02m 12s').")
  >> OPTIONS(description="Per-command telemetry breakdown array. Contains individual command rows ('find --deep', 'fix') plus a summary row with label='total'. Always exclude label='total' when aggregating.")
)
OPTIONS (
  format = 'NEWLINE_DELIMITED_JSON',
  uris = ['gs://${TELEMETRY_BUCKET}/codemender-finops-jsonl/*.jsonl'],
  ignore_unknown_values = TRUE,
  description = "Granular run-level CodeMender DevSecOps & Gemini Enterprise FinOps telemetry (1 row per GitHub Actions run). Backed by immutable NDJSON records in Cloud Storage."
);
EOF

echo "==> [4/4] Creating FinOps Executive Views (${BQ_DATASET}.v_repository_finops_summary & v_command_bucket_breakdown)..."
bq --location="${BQ_LOCATION}" --project_id="${PROJECT_ID}" query --use_legacy_sql=false <<EOF
CREATE OR REPLACE VIEW \`${PROJECT_ID}.${BQ_DATASET}.v_repository_finops_summary\` (
  repository OPTIONS(description="Full GitHub repository identifier in 'owner/repo' format."),
  repository_name OPTIONS(description="Short GitHub repository name without owner prefix."),
  scan_mode OPTIONS(description="CodeMender scan mode ('deep', 'diff', or 'quick')."),
  total_scans OPTIONS(description="Total number of distinct GitHub Actions workflow runs for this repository and scan_mode."),
  last_scan_utc OPTIONS(description="UTC timestamp of the most recent scan run."),
  total_findings_detected OPTIONS(description="Cumulative open vulnerabilities detected across runs."),
  total_findings_remediated OPTIONS(description="Cumulative vulnerabilities autonomously fixed and committed by 'cm fix' across runs."),
  total_input_tokens OPTIONS(description="Total Gemini Enterprise input tokens across runs (already includes total_cached_tokens)."),
  total_cached_tokens OPTIONS(description="Subset of total_input_tokens served from Gemini Enterprise Context Cache at a 75% discount."),
  total_output_tokens OPTIONS(description="Total generated output tokens across runs."),
  total_thought_tokens OPTIONS(description="Total internal reasoning/thinking tokens across runs."),
  total_tokens OPTIONS(description="Total tokens consumed across runs (total_input_tokens + total_output_tokens + total_thought_tokens)."),
  avg_cache_hit_pct OPTIONS(description="Average context cache hit percentage across runs."),
  total_duration_sec OPTIONS(description="Cumulative active CLI runtime duration in seconds."),
  estimated_cost_usd OPTIONS(description="Total estimated Gemini Enterprise cost in USD (Uncached Input @ \$1.25/1M + Cached Input @ \$0.3125/1M + Output & Thought @ \$10.00/1M).")
)
OPTIONS(
  description="Primary FinOps & DevSecOps executive summary view aggregated by repository and scan_mode. Includes scan counts, detected vs. remediated vulnerabilities, token totals, cache hit rate, duration, and estimated USD cost."
) AS
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

CREATE OR REPLACE VIEW \`${PROJECT_ID}.${BQ_DATASET}.v_command_bucket_breakdown\` (
  event_timestamp OPTIONS(description="UTC timestamp of the workflow run."),
  repository OPTIONS(description="Full GitHub repository identifier ('owner/repo')."),
  scan_mode OPTIONS(description="Scan mode ('deep', 'diff', or 'quick')."),
  github_run_id OPTIONS(description="Unique GitHub Actions workflow run ID."),
  command_bucket OPTIONS(description="CodeMender CLI command phase ('find --deep', 'find --diff', or 'fix'). Excludes 'total'."),
  requests OPTIONS(description="Number of CLI command invocations in this phase."),
  input_tokens OPTIONS(description="Total input tokens in this command phase (already includes cached_tokens)."),
  cached_tokens OPTIONS(description="Subset of input_tokens served from Gemini Enterprise Context Cache."),
  output_tokens OPTIONS(description="Generated output tokens in this command phase."),
  thought_tokens OPTIONS(description="Internal reasoning/thinking tokens in this command phase."),
  total_tokens OPTIONS(description="Total tokens in this command phase (input_tokens + output_tokens + thought_tokens)."),
  cache_hit_pct OPTIONS(description="Context cache hit percentage for this command phase."),
  duration_seconds OPTIONS(description="Active execution duration in seconds for this command phase."),
  duration_formatted OPTIONS(description="Human-readable duration for this command phase (e.g., '15m 09s').")
)
OPTIONS(
  description="Granular command-phase view comparing detection ('find --deep', 'find --diff') vs. autonomous patch generation ('fix'). Pre-filters out the 'total' summary row to prevent double-counting."
) AS
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
