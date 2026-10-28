# 🛡️ CodeMender Enterprise Reusable Workflows

**Enterprise DevSecOps Reference Architecture (100% Stateless Runner)** for running **Google Cloud CodeMender (`cm`)** across multiple application repositories via **GitHub Actions Reusable Workflows (`workflow_call`)**, checked against enterprise DevSecOps engineering practices.

This repository centralizes keyless Zero-Trust authentication (GCP Workload Identity Federation bound to `assertion.job_workflow_ref`), SHA-256 binary integrity verification for the `cm` CLI, pre-flight health checks (`cm health`), AI-driven vulnerability scanning (`deep`, `diff`, or `quick` modes) with deterministic cron jitter, native **SARIF v2.1.0** publication to GitHub Code Scanning / ASPM, autonomous **Remediation Pull Requests (`cm fix` + `gh pr`)** with atomic commits per vulnerability, a **Fail-Closed** PR Security Gate, and immutable append-only (WORM) FinOps token telemetry (`cm stats --json`) and SARIF archiving in Google Cloud Storage.

---

## 🏗️ Enterprise DevSecOps Architecture (100% Stateless Runner + Zero-Trust WIF + SARIF + Auto-PR)

Designed for enterprise engineering and DevSecOps platform teams, **GitHub Actions runners operate 100% statelessly**—eliminating the need to synchronize or persist the local SQLite database (`state.db`) across runs:

* **Immutable Software Supply Chain (Supply-Chain Pinning):** All official GitHub and Google actions are pinned to full-length 40-character commit SHAs, zero third-party community actions are used, and the `cm` CLI binary's SHA-256 digest is logged on every run (and optionally enforced via `cm_sha256`).
* **Zero-Trust WIF (`job_workflow_ref` Binding):** The Google Cloud STS OIDC provider enforces that tokens can only be minted by jobs executing this central reusable workflow (`codemender-reusable.yml`), preventing arbitrary workflows on developer branches from impersonating the Service Account.
* **Immutable Audit Trail (WORM / Append-Only):** The GCS telemetry bucket enforces `roles/storage.objectCreator` + `--no-clobber` + WORM retention (`--retention-period=365d`) and Public Access Prevention, ensuring no runner can overwrite or delete historical security reports or FinOps telemetry.
* **Vulnerability Lifecycle & Deduplication (For AppSec / DevSecOps):** Managed natively via **SARIF v2.1.0** in **GitHub Code Scanning** (or downstream ASPM platforms such as **Wiz** or DefectDojo), eliminating SQLite race conditions and CLI silos.
* **Autonomous Patch Delivery (For Application Developers):** Within the same ephemeral execution, `cm fix` generates and verifies patches via **Gemini Enterprise** while the official GitHub CLI (`gh pr`) opens a **Pull Request** with 1 atomic commit (`--no-verify`) per remediated vulnerability—with full support for GitHub App tokens (`secrets.pr_token`) to trigger required downstream CI checks.

---

## 📂 Repository Structure

| File | Description |
| :--- | :--- |
| [`.github/workflows/codemender-reusable.yml`](.github/workflows/codemender-reusable.yml) | **Central Reusable DevSecOps Workflow (`workflow_call`)**: 100% stateless, fail-closed, free of `${{ }}` script injection, 40-char SHA-pinned actions, deterministic cron jitter, WIF credential relocation & post-run shredding, SARIF v2.1.0 upload, and native PR creation with 1 atomic commit per fixed vulnerability. |
| [`examples/caller-repo/.github/workflows/codemender-monthly-async.yml`](examples/caller-repo/.github/workflows/codemender-monthly-async.yml) | **Monthly / On-Demand Async Audit Template**: Declarative caller workflow with explicit least-privilege permissions that application teams copy to run scheduled `--deep` scans and receive automated remediation Pull Requests. |
| [`examples/caller-repo/.github/workflows/codemender-pr-gate.yml`](examples/caller-repo/.github/workflows/codemender-pr-gate.yml) | **Pull Request Security Gate Template (`--diff`, Read-Only)**: Operates with strict `contents: read` and `pull-requests: read` permissions, analyzing only modified PR code and its 1-hop callers/callees in fail-closed mode. |
| [`examples/caller-repo/.cmignore`](examples/caller-repo/.cmignore) | **Enterprise `.cmignore` Template**: Excludes test suites, mocks, generated code (Protobuf/OpenAPI), internal tooling folders (`.cm_project/`, `.exploit/`), and static assets to optimize scan latency and Gemini Enterprise token consumption. |
| [`scripts/setup-enterprise-wif-and-gcs.sh`](scripts/setup-enterprise-wif-and-gcs.sh) | **GCP Zero-Trust & WORM Bootstrap Script**: Includes pre-flight operator permission checks and provisions the Service Account, WIF Pool/Provider with `assertion.job_workflow_ref` enforcement, and the append-only GCS bucket (`roles/storage.objectCreator`, `--public-access-prevention`, WORM retention, and optional Cloud KMS CMEK). |
| [`scripts/setup-finops-bigquery.sh`](scripts/setup-finops-bigquery.sh) | **BigQuery FinOps Analytics Bootstrap Script**: Includes pre-flight operator permission checks and provisions the `codemender_finops` BigQuery dataset, the serverless External Table (`scan_telemetry`) over `gs://<bucket>/codemender-finops-jsonl/*.jsonl`, and Executive Views (`v_repository_finops_summary`, `v_command_bucket_breakdown`). |
| [`docs/ENTERPRISE_ARCHITECTURE_GUIDE.md`](docs/ENTERPRISE_ARCHITECTURE_GUIDE.md) | **Enterprise Architecture & Customer Onboarding Guide**: Step-by-step reference documentation covering the Hub-and-Spoke topology, multi-team consumption model ([`Cotomacio/team-a-payments`](https://github.com/Cotomacio/team-a-payments) and [`Cotomacio/team-b-checkout`](https://github.com/Cotomacio/team-b-checkout) live demos), BigQuery FinOps telemetry, and security hardening controls. |

---

## 🔐 Required Operator Permissions for Bootstrap Scripts

Both bootstrap scripts run an automated **Pre-Flight Check** before provisioning resources. Ensure the administrator executing the scripts holds the following IAM roles on the target Google Cloud project:

### 1. [`scripts/setup-enterprise-wif-and-gcs.sh`](scripts/setup-enterprise-wif-and-gcs.sh)
* `roles/serviceusage.serviceUsageAdmin` — Enable required Google Cloud APIs (`aiplatform.googleapis.com` for Gemini Enterprise backward-compatible SDK endpoints, `iam`, `iamcredentials`, `sts`, `storage`).
* `roles/iam.serviceAccountAdmin` — Create the `codemender-ci` Service Account and bind WIF impersonation policy.
* `roles/iam.workloadIdentityPoolAdmin` — Create and configure the Workload Identity Pool and OIDC Provider.
* `roles/resourcemanager.projectIamAdmin` — Grant project-level IAM roles to the Service Account.
* `roles/storage.admin` — Create the WORM GCS telemetry bucket and bind bucket-level `roles/storage.objectCreator`.

### 2. [`scripts/setup-finops-bigquery.sh`](scripts/setup-finops-bigquery.sh)
* `roles/serviceusage.serviceUsageAdmin` — Enable `bigquery.googleapis.com` (if not already enabled).
* `roles/bigquery.dataEditor` (or `roles/bigquery.admin`) + `roles/bigquery.jobUser` — Create the `codemender_finops` dataset, External Table (`scan_telemetry`), and executive FinOps views.
* `roles/storage.objectViewer` on `gs://<TELEMETRY_BUCKET>` — Required by BigQuery to query `.jsonl` telemetry objects in Cloud Storage.
