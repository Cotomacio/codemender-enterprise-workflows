#!/usr/bin/env bash
# =============================================================================
# CodeMender Enterprise Bootstrap: GCP Service Account + WIF + WORM GCS Bucket
# =============================================================================
# Provisions the Google Cloud infrastructure required to run the CodeMender
# Reusable GitHub Actions Workflow across an entire GitHub Organization (100+
# repositories) with Zero-Trust OIDC binding and append-only audit storage:
#   1. Enables Vertex AI, IAM Credentials, STS, and Cloud Storage APIs.
#   2. Creates the dedicated `codemender-ci` Service Account.
#   3. Grants `roles/aiplatform.user` and `roles/serviceusage.serviceUsageConsumer`.
#   4. Creates a hardened GCS Bucket (`--uniform-bucket-level-access`,
#      `--public-access-prevention`, configurable WORM `--retention-period`,
#      optional Cloud KMS CMEK) and grants ONLY `roles/storage.objectCreator`
#      (true append-only audit trail — runners cannot delete or overwrite logs).
#   5. Creates/updates an Organization-wide Workload Identity Pool & OIDC Provider
#      with `assertion.job_workflow_ref` enforcement so ONLY jobs executing the
#      central reusable workflow can impersonate the Service Account.
#
# Usage:
#   export PROJECT_ID="your-gcp-project-id"
#   export GITHUB_ORG="your-github-org"
#   ./scripts/setup-enterprise-wif-and-gcs.sh
# =============================================================================
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?ERROR: Set PROJECT_ID environment variable}"
GITHUB_ORG="${GITHUB_ORG:?ERROR: Set GITHUB_ORG environment variable}"
HUB_REPO="${HUB_REPO:-codemender-enterprise-workflows}"
ENFORCE_JOB_WORKFLOW_REF="${ENFORCE_JOB_WORKFLOW_REF:-true}"
SA_NAME="${SA_NAME:-codemender-ci}"
POOL_ID="${POOL_ID:-github-org-pool}"
PROVIDER_ID="${PROVIDER_ID:-codemender-oidc}"
TELEMETRY_BUCKET="${TELEMETRY_BUCKET:-${PROJECT_ID}-codemender-telemetry}"
BUCKET_LOCATION="${BUCKET_LOCATION:-US}"
RETENTION_PERIOD="${RETENTION_PERIOD:-365d}"
KMS_KEY_NAME="${KMS_KEY_NAME:-}"

SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "==> [1/6] Enabling required Google Cloud APIs on project ${PROJECT_ID}..."
gcloud services enable \
  aiplatform.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com \
  storage.googleapis.com \
  --project="${PROJECT_ID}"

echo "==> [2/6] Creating Service Account ${SA_EMAIL}..."
if ! gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud iam service-accounts create "${SA_NAME}" \
    --project="${PROJECT_ID}" \
    --display-name="CodeMender Enterprise CI/CD Runner"
fi

echo "==> [3/6] Granting Vertex AI & Service Usage roles to ${SA_EMAIL}..."
for ROLE in "roles/aiplatform.user" "roles/serviceusage.serviceUsageConsumer"; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${ROLE}" \
    --condition=None \
    --quiet >/dev/null
done

echo "==> [4/6] Creating & Hardening Append-Only GCS Telemetry Bucket gs://${TELEMETRY_BUCKET}..."
if ! gcloud storage buckets describe "gs://${TELEMETRY_BUCKET}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  CREATE_ARGS=(
    "--project=${PROJECT_ID}"
    "--location=${BUCKET_LOCATION}"
    "--uniform-bucket-level-access"
    "--public-access-prevention"
  )
  if [ -n "${RETENTION_PERIOD}" ]; then
    CREATE_ARGS+=("--retention-period=${RETENTION_PERIOD}")
  fi
  if [ -n "${KMS_KEY_NAME}" ]; then
    CREATE_ARGS+=("--default-encryption-key=${KMS_KEY_NAME}")
  fi
  gcloud storage buckets create "gs://${TELEMETRY_BUCKET}" "${CREATE_ARGS[@]}"
else
  UPDATE_ARGS=(
    "--project=${PROJECT_ID}"
    "--uniform-bucket-level-access"
    "--public-access-prevention"
  )
  if [ -n "${RETENTION_PERIOD}" ]; then
    UPDATE_ARGS+=("--retention-period=${RETENTION_PERIOD}")
  fi
  if [ -n "${KMS_KEY_NAME}" ]; then
    UPDATE_ARGS+=("--default-encryption-key=${KMS_KEY_NAME}")
  fi
  gcloud storage buckets update "gs://${TELEMETRY_BUCKET}" "${UPDATE_ARGS[@]}" >/dev/null
fi

# Enforce true append-only immutability: grant roles/storage.objectCreator (create-only)
# and remove roles/storage.objectUser if present from earlier configurations.
gcloud storage buckets add-iam-policy-binding "gs://${TELEMETRY_BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectCreator" \
  --quiet >/dev/null

gcloud storage buckets remove-iam-policy-binding "gs://${TELEMETRY_BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectUser" \
  --quiet >/dev/null 2>&1 || true

echo "==> [5/6] Configuring Workload Identity Pool (${POOL_ID}) & Zero-Trust OIDC Provider (${PROVIDER_ID})..."
# Ensure GitHub OIDC issuer is allowed if constraints/iam.workloadIdentityPoolProviders is enforced at Org level
gcloud resource-manager org-policies allow iam.workloadIdentityPoolProviders \
  "is:https://token.actions.githubusercontent.com" \
  --project="${PROJECT_ID}" >/dev/null 2>&1 || true

if ! gcloud iam workload-identity-pools describe "${POOL_ID}" \
  --project="${PROJECT_ID}" --location="global" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools create "${POOL_ID}" \
    --project="${PROJECT_ID}" \
    --location="global" \
    --display-name="GitHub Actions Enterprise Pool"
fi

ATTR_MAPPING="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.job_workflow_ref=assertion.job_workflow_ref"
if [ "${ENFORCE_JOB_WORKFLOW_REF}" = "true" ]; then
  ATTR_CONDITION="assertion.repository_owner == '${GITHUB_ORG}' && assertion.job_workflow_ref.startsWith('${GITHUB_ORG}/${HUB_REPO}/.github/workflows/codemender-reusable.yml@')"
else
  ATTR_CONDITION="assertion.repository_owner == '${GITHUB_ORG}'"
fi

if ! gcloud iam workload-identity-pools providers describe "${PROVIDER_ID}" \
  --project="${PROJECT_ID}" --location="global" \
  --workload-identity-pool="${POOL_ID}" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_ID}" \
    --project="${PROJECT_ID}" \
    --location="global" \
    --workload-identity-pool="${POOL_ID}" \
    --display-name="GitHub Actions OIDC" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="${ATTR_MAPPING}" \
    --attribute-condition="${ATTR_CONDITION}"
else
  gcloud iam workload-identity-pools providers update-oidc "${PROVIDER_ID}" \
    --project="${PROJECT_ID}" \
    --location="global" \
    --workload-identity-pool="${POOL_ID}" \
    --attribute-mapping="${ATTR_MAPPING}" \
    --attribute-condition="${ATTR_CONDITION}" >/dev/null
fi

PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
POOL_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}"
WIF_PROVIDER_RESOURCE="${POOL_RESOURCE}/providers/${PROVIDER_ID}"

echo "==> [6/6] Binding GitHub Organization (${GITHUB_ORG}) to Service Account ${SA_EMAIL}..."
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/${POOL_RESOURCE}/attribute.repository_owner/${GITHUB_ORG}" \
  --quiet >/dev/null

cat <<EOF

================================================================================
✅ CodeMender Enterprise GCP Bootstrap Complete! (Regulated Zero-Trust Mode)
================================================================================
Configure the following GitHub Organization Variables (Settings -> Secrets and
variables -> Actions -> Variables -> New organization variable):

  GCP_QUOTA_PROJECT     = ${PROJECT_ID}
  GCP_WIF_PROVIDER      = ${WIF_PROVIDER_RESOURCE}
  GCP_SA_EMAIL          = ${SA_EMAIL}
  GCP_TELEMETRY_BUCKET  = ${TELEMETRY_BUCKET}

Security Controls Applied:
  - WIF Job Workflow Binding : ${ATTR_CONDITION}
  - GCS Audit Bucket Role    : roles/storage.objectCreator (Append-Only)
  - GCS Public Access        : Enforced Prevention + Uniform Bucket-Level Access
  - GCS WORM Retention       : ${RETENTION_PERIOD:-disabled}
================================================================================
EOF
