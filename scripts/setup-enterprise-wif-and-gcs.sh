#!/usr/bin/env bash
# =============================================================================
# Enterprise WIF & GCS Bootstrap for CodeMender GitHub Actions (100+ Repos)
# =============================================================================
# Provisions:
#   1. Service Account (`codemender-ci`) with Vertex AI + Service Usage roles.
#   2. Workload Identity Pool & OIDC Provider scoped to the entire GitHub Org
#      (`assertion.repository_owner == GITHUB_ORG`), enabling all repositories
#      in the organization to authenticate keylessly without per-repo bindings.
#   3. Optional GCS Bucket for append-only FinOps token telemetry and SARIF logs
#      (runners remain 100% stateless — no SQLite `state.db` synchronization).
# =============================================================================

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-prj-bcb-gcpsecops}"
GITHUB_ORG="${GITHUB_ORG:-Cotomacio}"
SA_NAME="${SA_NAME:-codemender-ci}"
POOL_ID="${POOL_ID:-github-org-pool}"
PROVIDER_ID="${PROVIDER_ID:-codemender-oidc}"
TELEMETRY_BUCKET="${TELEMETRY_BUCKET:-${PROJECT_ID}-codemender-telemetry}"
BUCKET_LOCATION="${BUCKET_LOCATION:-SOUTHAMERICA-EAST1}"

echo "==> [1/6] Enabling required Google Cloud APIs on ${PROJECT_ID}..."
gcloud services enable \
  aiplatform.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com \
  sts.googleapis.com \
  storage.googleapis.com \
  --project="${PROJECT_ID}"

SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "==> [2/6] Creating Service Account ${SA_EMAIL}..."
if ! gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud iam service-accounts create "${SA_NAME}" \
    --project="${PROJECT_ID}" \
    --display-name="CodeMender Enterprise CI/CD"
fi

echo "==> [3/6] Granting Vertex AI & Service Usage IAM roles..."
for ROLE in "roles/aiplatform.user" "roles/serviceusage.serviceUsageConsumer"; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${ROLE}" \
    --condition=None \
    --quiet >/dev/null
done

echo "==> [4/6] Creating GCS Bucket gs://${TELEMETRY_BUCKET} for FinOps telemetry & SARIF archives..."
if ! gcloud storage buckets describe "gs://${TELEMETRY_BUCKET}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://${TELEMETRY_BUCKET}" \
    --project="${PROJECT_ID}" \
    --location="${BUCKET_LOCATION}" \
    --uniform-bucket-level-access
fi

gcloud storage buckets add-iam-policy-binding "gs://${TELEMETRY_BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectUser" \
  --quiet >/dev/null

echo "==> [5/6] Configuring Workload Identity Pool (${POOL_ID}) & OIDC Provider (${PROVIDER_ID})..."
if ! gcloud iam workload-identity-pools describe "${POOL_ID}" --project="${PROJECT_ID}" --location="global" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools create "${POOL_ID}" \
    --project="${PROJECT_ID}" \
    --location="global" \
    --display-name="GitHub Actions Org Pool"
fi

if ! gcloud iam workload-identity-pools providers describe "${PROVIDER_ID}" \
  --project="${PROJECT_ID}" --location="global" --workload-identity-pool="${POOL_ID}" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_ID}" \
    --project="${PROJECT_ID}" \
    --location="global" \
    --workload-identity-pool="${POOL_ID}" \
    --display-name="GitHub Actions OIDC" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
    --attribute-condition="assertion.repository_owner == '${GITHUB_ORG}'"
fi

POOL_RESOURCE=$(gcloud iam workload-identity-pools describe "${POOL_ID}" \
  --project="${PROJECT_ID}" --location="global" --format="value(name)")

echo "==> [6/6] Binding Workload Identity User across GitHub Org '${GITHUB_ORG}'..."
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/${POOL_RESOURCE}/attribute.repository_owner/${GITHUB_ORG}" \
  --quiet >/dev/null

PROVIDER_RESOURCE=$(gcloud iam workload-identity-pools providers describe "${PROVIDER_ID}" \
  --project="${PROJECT_ID}" --location="global" --workload-identity-pool="${POOL_ID}" --format="value(name)")

cat <<EOF

=============================================================================
✅ Enterprise Bootstrap Complete!
Configure these 4 Organization-Level Variables in GitHub
(Organization Settings -> Secrets and variables -> Actions -> Variables):
=============================================================================
  GCP_QUOTA_PROJECT    : ${PROJECT_ID}
  GCP_WIF_PROVIDER     : ${PROVIDER_RESOURCE}
  GCP_SA_EMAIL         : ${SA_EMAIL}
  GCP_TELEMETRY_BUCKET : ${TELEMETRY_BUCKET}
=============================================================================
EOF
