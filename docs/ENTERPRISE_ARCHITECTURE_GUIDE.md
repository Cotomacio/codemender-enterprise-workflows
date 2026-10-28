# 🛡️ Google Cloud CodeMender — Enterprise DevSecOps Reference Architecture & Regulated-Industry Onboarding Guide

**Target Audience:** CISOs, Enterprise Cloud & Security Architects, DevSecOps Platform Teams, Application Engineering Leads, and External Compliance Auditors  
**Architecture Pattern:** Hub-and-Spoke GitHub Actions Reusable Workflow (`workflow_call`) + 100% Stateless Runner + Zero-Trust Keyless GCP WIF (`job_workflow_ref` Bound) + Native SARIF v2.1.0 + Autonomous Remediation PRs + WORM Append-Only FinOps Telemetry  
**Compliance Alignment:** PCI-DSS v4.0, SOC 2 Type II, ISO/IEC 27001:2022, NIST SP 800-218 (SSDF v1.1), CIS GitHub & GCP Benchmarks, SLSA Build L2, SEC Rule 17a-4, DORA, BACEN Res. 4.893  
**Live Reference Repositories:**
- **Central Governance Hub:** [`Cotomacio/codemender-enterprise-workflows`](https://github.com/Cotomacio/codemender-enterprise-workflows)
- **Sample Consumer Repository (Team A):** [`Cotomacio/team-a-payments`](https://github.com/Cotomacio/team-a-payments)

---

## Executive Summary

When rolling out AI-powered vulnerability detection and autonomous code remediation (**Google Cloud CodeMender CLI — `cm`**) across **100+ to 1,000+ application repositories** in highly regulated enterprises (banking, financial services, healthcare, telecommunications, and critical infrastructure), copying complex CI/CD scripts into every repository creates severe governance, security, and maintenance debt.

This guide documents a production-verified, **Regulated-Industry Hub-and-Spoke DevSecOps Reference Architecture** where:
1. **The Central AppSec / Platform Team** maintains a **single reusable workflow repository** (`codemender-enterprise-workflows`) hardened against script injection, tag hijacking, lateral OIDC token minting, and fail-open errors.
2. **Application Teams (Team A, Team B, ... Team N)** onboard in **under 5 minutes** by dropping lightweight, declarative YAML caller files (`~40 lines` with explicit least-privilege `permissions:`) and a `.cmignore` policy into their repository—with **zero secrets, zero JSON service account keys, and zero bash scripts** to maintain.
3. **Every execution is 100% Stateless, Fail-Closed, and Zero-Trust:**
   - **For AppSec & Risk Governance:** Vulnerability lifecycle, deduplication, and triage happen natively via **SARIF v2.1.0** in **GitHub Code Scanning** (or downstream ASPM tools such as DefectDojo, Wiz, or Security Command Center), while immutable audit artifacts are archived with `--no-clobber` to a WORM-capable Google Cloud Storage bucket (`roles/storage.objectCreator`).
   - **For Application Developers:** CodeMender autonomously generates and validates patches (`cm fix`) and uses the official GitHub CLI (`gh pr`) to open a **Pull Request with 1 atomic Git commit per remediated vulnerability** for standard human code review.

> [!IMPORTANT]
> **Why Stateless Runners?**  
> CodeMender maintains a local SQLite database (`.cm_project/state.db`) during execution. Synchronizing a binary SQLite file across concurrent ephemeral CI runners via object storage introduces race conditions and state corruption. By treating every runner as **100% stateless** and exporting **SARIF v2.1.0 + Automated PRs + Append-Only GCS Telemetry** inside the same ephemeral job, this architecture scales horizontally to thousands of repositories with zero locking or state contention.

---

## 1. End-to-End Architecture Overview

### 1.1 High-Level Hub-and-Spoke Topology

```mermaid
flowchart TB
    subgraph GH_ORG["GitHub Organization (100+ to 1,000+ Repositories)"]
        direction TB
        ORG_VARS["🔐 GitHub Organization Variables\n• GCP_QUOTA_PROJECT\n• GCP_WIF_PROVIDER\n• GCP_SA_EMAIL\n• GCP_TELEMETRY_BUCKET"]

        subgraph SPOKES["Application Team Repositories (Consumers / Spokes)"]
            TEAM_A["📦 Team A: team-a-payments\n• codemender-monthly-async.yml (write)\n• codemender-pr-gate.yml (read-only)\n• .cmignore"]
            TEAM_B["📦 Team B: team-b-checkout\n• codemender-monthly-async.yml (write)\n• codemender-pr-gate.yml (read-only)\n• .cmignore"]
            TEAM_N["📦 Team N: 100+ Microservices\n• codemender-monthly-async.yml (write)\n• codemender-pr-gate.yml (read-only)\n• .cmignore"]
        end

        subgraph HUB["Central DevSecOps Repository (Hub)"]
            REUSABLE["🛡️ codemender-enterprise-workflows\n.github/workflows/codemender-reusable.yml\n(workflow_call • SHA-Pinned • Fail-Closed)"]
        end

        subgraph OUTPUTS["Developer & AppSec Native Outputs (Per Repo)"]
            SARIF_OUT["📊 GitHub Code Scanning\n(SARIF v2.1.0 Alerts & Deduplication)"]
            AUTO_PR["🔀 Automated Pull Request (gh CLI)\n(1 Atomic Commit per Fixed Vulnerability)"]
        end
    end

    subgraph GCP["Google Cloud Platform (Central Governance Project: codemender-latam)"]
        WIF["🔑 Workload Identity Federation\nPool: github-org-pool / Provider: codemender-oidc\nCondition: repository_owner AND job_workflow_ref"]
        SA["👤 Service Account\ncodemender-ci@...\n(aiplatform.user + storage.objectCreator)"]
        AR["📦 Artifact Registry\ncmoc-prod/codemender-cli-production\n(cm-linux-amd64.zip + SHA-256 Audit)"]
        VERTEX["🧠 Vertex AI / Gemini Models\nCodeMender Engine\n(cm find & cm fix)"]
        GCS["🪣 Cloud Storage WORM Audit Bucket\ngs://...-codemender-telemetry\n(objectCreator + 365d Retention + Public Access Prevention)"]
    end

    ORG_VARS -.->|"Inherited by"| SPOKES
    TEAM_A & TEAM_B & TEAM_N ==>|"uses: workflow_call"| REUSABLE
    REUSABLE -->|"1. Keyless OIDC Token\n(Verified job_workflow_ref)"| WIF
    WIF -->|"2. Short-Lived Impersonation"| SA
    REUSABLE -->|"3. HTTPS Download + SHA-256 Check"| AR
    SA -->|"4. AI Deep / Diff Scan & Patch"| VERTEX
    REUSABLE -->|"5a. Upload Normalized SARIF"| SARIF_OUT
    REUSABLE -->|"5b. Push Atomic Commits & Open PR"| AUTO_PR
    SA -->|"5c. Append-Only Upload (--no-clobber)"| GCS
```

---

### 1.2 Stateless Execution Sequence (Inside a Single Ephemeral Run)

```mermaid
sequenceDiagram
    autonumber
    actor Trigger as Schedule (Cron) / PR / Dispatch
    participant Spoke as Consumer Repo (team-a-payments)
    participant Hub as Central Reusable Workflow
    participant GCP as GCP (Zero-Trust WIF + Vertex AI + GCS)
    participant GH as GitHub (Code Scanning & PRs)

    Trigger->>Spoke: Trigger workflow (monthly cron, PR, or manual dispatch)
    Spoke->>Hub: Invoke workflow_call with Org Variables & least-privilege permissions
    Hub->>Hub: Validate inputs (zero script injection) & apply deterministic cron jitter
    Hub->>GCP: Exchange GitHub OIDC JWT via WIF (enforcing assertion.job_workflow_ref)
    GCP-->>Hub: Return short-lived token (relocated to $RUNNER_TEMP/gcp-creds.json)
    Hub->>GCP: Download cm CLI binary & log/verify SHA-256 digest
    Hub->>Hub: Purge untrusted .cm_project/.codemender, update .git/info/exclude & run cm init + cm health
    Hub->>GCP: Execute cm find (--deep-workers or --diff-workers) & capture PIPESTATUS[0]
    GCP-->>Hub: Populate ephemeral .cm_project/state.db with findings & token stats
    Hub->>Hub: Export SARIF v2.1.0, OPEN findings JSON & stats.json; normalize SARIF URIs
    Hub->>GH: Upload SARIF v2.1.0 to GitHub Code Scanning
    alt enable_autofix == true AND target findings > 0
        loop For each target finding (up to fix_limit)
            Hub->>GCP: Execute cm fix <FINDING_ID> --sandbox=false --yes
            GCP-->>Hub: Generate & validate security patch
            Hub->>Hub: git commit --no-verify -m "fix(security): remediate <Title> [<Severity>]"
        end
        Hub->>GH: Push branch & create/update PR via gh CLI (codemender/remediate-main)
    end
    opt gcp_telemetry_bucket is configured
        Hub->>GCP: Archive SARIF, findings-open.json & stats.json to GCS (--no-clobber)
    end
    opt enforce_gate == true (PR Security Gate — Fail-Closed)
        Hub->>Hub: Fail job (exit 1) if scan_exit_code != 0 OR open CRITICAL/HIGH > 0
    end
    Hub->>Hub: Always shred temporary WIF credentials ($RUNNER_TEMP/gcp-creds.json)
```

---

## 2. Step-by-Step Implementation Guide

### Step 1: Provision Google Cloud Infrastructure (One-Time Setup)

The Platform / Cloud Security team provisions **one** central Google Cloud project (in our working implementation, `codemender-latam`, Project Number `353807816023`) that acts as the billing, quota, and telemetry hub for all repositories in the GitHub Organization.

#### 1.1 Automated Bootstrap Script
The repository includes [`scripts/setup-enterprise-wif-and-gcs.sh`](https://github.com/Cotomacio/codemender-enterprise-workflows/blob/main/scripts/setup-enterprise-wif-and-gcs.sh), which automates all 6 provisioning steps with regulated-enterprise security controls:

```bash
export PROJECT_ID="codemender-latam"
export GITHUB_ORG="Cotomacio"
export HUB_REPO="codemender-enterprise-workflows"
export RETENTION_PERIOD="365d"   # 1-year WORM audit retention (PCI-DSS Req 10.7 / SOC 2)
./scripts/setup-enterprise-wif-and-gcs.sh
```

#### 1.2 What the Bootstrap Configures Under the Hood

1. **Google Cloud APIs Enabled:**
   - `aiplatform.googleapis.com` (Vertex AI / Gemini models powering CodeMender)
   - `iam.googleapis.com`, `iamcredentials.googleapis.com`, `sts.googleapis.com` (Keyless OIDC token exchange)
   - `cloudresourcemanager.googleapis.com`, `storage.googleapis.com` (Project metadata & FinOps telemetry)

2. **Dedicated Least-Privilege Service Account:**
   - **Email:** `codemender-ci@codemender-latam.iam.gserviceaccount.com`
   - **Project IAM Roles:**
     - `roles/aiplatform.user` — Required to invoke CodeMender Gemini models on Vertex AI.
     - `roles/serviceusage.serviceUsageConsumer` — Required to consume project quota.
   - **Bucket IAM Role (True Append-Only Audit Trail):**
     - `roles/storage.objectCreator` on `gs://codemender-latam-codemender-telemetry` — Permits **only** `storage.objects.create`. Runners **cannot** read other repositories' SARIF reports, list bucket contents, or overwrite/delete historical audit records (`storage.objects.delete` is denied).

3. **Zero-Trust Workload Identity Federation (WIF) Bound to the Central Workflow:**
   - **Workload Identity Pool:** `github-org-pool`
   - **OIDC Provider:** `codemender-oidc`
   - **Issuer URI:** `https://token.actions.githubusercontent.com`
   - **Attribute Mapping:**
     ```text
     google.subject=assertion.sub
     attribute.repository=assertion.repository
     attribute.repository_owner=assertion.repository_owner
     attribute.job_workflow_ref=assertion.job_workflow_ref
     ```
   - **Zero-Trust Attribute Condition (`repository_owner` + `job_workflow_ref`):**
     ```cel
     assertion.repository_owner == 'Cotomacio' && assertion.job_workflow_ref.startsWith('Cotomacio/codemender-enterprise-workflows/.github/workflows/codemender-reusable.yml@')
     ```
     > [!CAUTION]
     > **Why `assertion.job_workflow_ref` Binding Is Critical for Regulated Enterprises:**  
     > If a WIF provider only checks `assertion.repository_owner == 'ORG'`, any developer with branch write access in any repository could create a custom `.github/workflows/hack.yml` that calls `google-github-actions/auth` directly and impersonates `codemender-ci` outside the governance of the central pipeline. By enforcing `assertion.job_workflow_ref.startsWith(...)` inside Google Cloud STS, **only jobs executing the central reusable workflow** can obtain a GCP access token.

   > [!NOTE]
   > **Enterprise GCP Organization Policy Tip (`constraints/iam.workloadIdentityPoolProviders`):**  
   > In regulated GCP Organizations where `constraints/iam.workloadIdentityPoolProviders` restricts allowed OIDC issuers, ensure the policy allow-lists `is:https://token.actions.githubusercontent.com` (including the `is:` prefix required by GCP Org Policy syntax).

4. **Hardened WORM FinOps & Security Audit Bucket:**
   - **Bucket URI:** `gs://codemender-latam-codemender-telemetry`
   - **Controls Enforced:**
     - `--uniform-bucket-level-access` (disables legacy per-object ACLs)
     - `--public-access-prevention` (blocks accidental public exposure at the bucket level)
     - `--retention-period=365d` (WORM retention policy preventing deletion or modification of archived SARIF and token telemetry prior to retention expiry)
     - Optional `--default-encryption-key=${KMS_KEY_NAME}` for Customer-Managed Encryption Keys (**Cloud KMS CMEK**)

---

### Step 2: Create the Central DevSecOps Repository (`codemender-enterprise-workflows`)

The Platform / AppSec team hosts the reusable workflow and onboarding templates in a single central repository:  
🔗 **[`https://github.com/Cotomacio/codemender-enterprise-workflows`](https://github.com/Cotomacio/codemender-enterprise-workflows)**

#### 2.1 Repository File Layout

```text
codemender-enterprise-workflows/
├── .github/
│   └── workflows/
│       └── codemender-reusable.yml              # Central workflow_call engine (569 lines, 0 external scripts)
├── docs/
│   └── ENTERPRISE_ARCHITECTURE_GUIDE.md         # This customer-shareable architecture & compliance guide
├── examples/
│   └── caller-repo/
│       ├── .cmignore                            # Token & scope optimization template
│       └── .github/
│           └── workflows/
│               ├── codemender-monthly-async.yml # Template 1: Monthly Deep Audit + Auto-PR (write)
│               └── codemender-pr-gate.yml       # Template 2: Fast PR Diff Security Gate (read-only)
├── scripts/
│   └── setup-enterprise-wif-and-gcs.sh          # Zero-Trust GCP WIF + WORM GCS bootstrap script
└── README.md
```

#### 2.2 Required GitHub Repository Permission for Cross-Repo Sharing
In the central repository (`codemender-enterprise-workflows`), navigate to:
- **Settings → Actions → General → Access**
- Select **"Accessible from repositories in the '<ORG>' organization"** (or make the central workflow repository public/internal as appropriate for your GitHub Enterprise plan).

---

### Step 3: Configure GitHub Organization Variables

Instead of configuring credentials in 100+ individual repositories, set **4 non-sensitive variables once** at the **GitHub Organization** level (**Organization Settings → Secrets and variables → Actions → Variables → New organization variable**):

| Variable Name | Value in Reference Implementation | Purpose |
| :--- | :--- | :--- |
| `GCP_QUOTA_PROJECT` | `codemender-latam` | GCP Project ID where Vertex AI & CodeMender APIs are enabled |
| `GCP_WIF_PROVIDER` | `projects/353807816023/locations/global/workloadIdentityPools/github-org-pool/providers/codemender-oidc` | Full Workload Identity Provider resource path |
| `GCP_SA_EMAIL` | `codemender-ci@codemender-latam.iam.gserviceaccount.com` | Service Account impersonated via short-lived OIDC token |
| `GCP_TELEMETRY_BUCKET` | `codemender-latam-codemender-telemetry` | Append-only WORM GCS bucket for SARIF & token cost archiving |

*(Note: For personal GitHub accounts or pilot testing on a single repository such as [`Cotomacio/team-a-payments`](https://github.com/Cotomacio/team-a-payments), these exact 4 variables can also be set at the **Repository Variables** level.)*

---

### Step 4: Deep Dive Into the Central Reusable Workflow ([`codemender-reusable.yml`](https://github.com/Cotomacio/codemender-enterprise-workflows/blob/main/.github/workflows/codemender-reusable.yml))

The central workflow [`.github/workflows/codemender-reusable.yml`](https://github.com/Cotomacio/codemender-enterprise-workflows/blob/main/.github/workflows/codemender-reusable.yml) is **100% self-contained** (`bash` + `jq` + `gh` CLI) and pinned to immutable 40-character commit SHAs for all official actions.

#### 4.1 Configurable Inputs & Secrets (`workflow_call` Interface)

| Input / Secret | Type | Default | Description |
| :--- | :---: | :---: | :--- |
| `gcp_project_id` | `string` (required) | — | GCP Project ID (`vars.GCP_QUOTA_PROJECT`) |
| `gcp_wif_provider` | `string` (required) | — | WIF Provider resource name (`vars.GCP_WIF_PROVIDER`) |
| `gcp_sa_email` | `string` (required) | — | Service Account email (`vars.GCP_SA_EMAIL`) |
| `gcp_telemetry_bucket` | `string` | `''` | Optional WORM GCS bucket name (`vars.GCP_TELEMETRY_BUCKET`) |
| `scan_path` | `string` | `'.'` | Subdirectory to scan (useful for monorepos) |
| `scan_mode` | `string` | `'deep'` | `'deep'` (full audit), `'diff'` (PR delta + 1-hop callers), or `'quick'` |
| `cm_location` | `string` | `'global'` | Vertex AI / CodeMender API location (`global`, `us-central1`, `europe-west1`, etc.) |
| `cm_model` | `string` | `''` | Optional Gemini model override |
| `cm_context` | `string` | `''` | Architectural or threat-model context passed via `-c` to `cm find` |
| `enable_autofix` | `boolean` | `true` | Run `cm fix` and open an automated remediation Pull Request |
| `fix_severities` | `string` | `'CRITICAL,HIGH'` | Severities targeted for auto-remediation and gating |
| `fix_limit` | `string` | `'5'` | Max vulnerabilities to auto-fix per execution (bounds run time & PR size) |
| `deep_workers` | `string` | `'8'` | Concurrent worker threads during `deep` scan (`--deep-workers`) |
| `diff_workers` | `string` | `'16'` | Concurrent worker threads during `diff` scan (`--diff-workers`) |
| `schedule_jitter_max_seconds` | `string` | `'300'` | Deterministic per-repo cron jitter window in seconds (`0` to disable) |
| `enforce_gate` | `boolean` | `false` | Fail the CI job (`exit 1`, **fail-closed**) if scan errors or open target findings remain |
| `upload_sarif` | `boolean` | `true` | Upload normalized SARIF v2.1.0 report to GitHub Code Scanning |
| `cm_version` | `string` | `'stable'` | CodeMender CLI version tag in Artifact Registry |
| `cm_sha256` | `string` | `''` | Optional expected 64-hex SHA-256 digest of `cm-linux-amd64.zip` |
| `secrets.wif_audience` | `secret` | — | Optional custom OIDC audience string if required by the WIF provider |
| `secrets.pr_token` | `secret` | — | Optional GitHub App token or PAT to push remediation branches and trigger downstream required CI checks |

#### 4.2 Critical Engineering Mechanisms Inside [`codemender-reusable.yml`](https://github.com/Cotomacio/codemender-enterprise-workflows/blob/main/.github/workflows/codemender-reusable.yml)

1. **Supply-Chain Pinning & Zero Script Injection ([Lines 180–219](https://github.com/Cotomacio/codemender-enterprise-workflows/blob/main/.github/workflows/codemender-reusable.yml#L180-L219)):**
   - Every official action (`actions/checkout`, `google-github-actions/auth`, `github/codeql-action/upload-sarif`, `actions/upload-artifact`) is pinned to its **immutable 40-character Git commit SHA** (satisfying CIS GitHub Benchmark 4.2.5 and SLSA Build L2).
   - Zero `${{ ... }}` expressions appear inside `run:` shell blocks. All inputs are passed through environment variables (`env:`) and validated against strict regexes (`^(deep|diff|quick)$`, `^[0-9]+$`, `^[a-zA-Z0-9._-]+$`), eliminating CWE-78 script injection.

2. **Deterministic Cron Jitter for 100+ Repo Scale ([Lines 221–230](https://github.com/Cotomacio/codemender-enterprise-workflows/blob/main/.github/workflows/codemender-reusable.yml#L221-L230)):**
   - When 100+ repositories share a monthly cron schedule (`0 6 1-7 * 1`), triggering simultaneously can exhaust regional or global Vertex AI API quotas (`429 Resource Exhausted`).
   - On `schedule` events, the workflow computes a deterministic hash of `$GITHUB_REPOSITORY` (`cksum`) modulo `schedule_jitter_max_seconds` (default `300s`), staggering starts smoothly across the window with zero manual coordination.

3. **WIF Credential Relocation & Post-Run Shredding ([Lines 240–256](https://github.com/Cotomacio/codemender-enterprise-workflows/blob/main/.github/workflows/codemender-reusable.yml#L240-L256), [Lines 566–569](https://github.com/Cotomacio/codemender-enterprise-workflows/blob/main/.github/workflows/codemender-reusable.yml#L566-L569)):**
   - `google-github-actions/auth` writes its short-lived OIDC credential file (`gha-creds-*.json`) directly into `$GITHUB_WORKSPACE`.
   - Because CodeMender runs `git checkout HEAD -- . && git clean -fd` inside `$GITHUB_WORKSPACE` to guarantee a clean worktree before scanning and patching, an unprotected credential file inside the workspace would be deleted mid-run.
   - The workflow relocates the credential file into `$RUNNER_TEMP/gcp-creds.json` (`chmod 600`), adds `.cm_project`, `.exploit`, and `gha-creds-*.json` to `.git/info/exclude`, and shreds the credential file in an `if: ${{ always() }}` final step.

4. **Direct Artifact Registry CLI Download + SHA-256 Integrity Verification ([Lines 258–279](https://github.com/Cotomacio/codemender-enterprise-workflows/blob/main/.github/workflows/codemender-reusable.yml#L258-L279)):**
   - Downloads `cm-linux-amd64.zip` from `https://artifactregistry.googleapis.com/download/v1/projects/cmoc-prod/locations/us/repositories/codemender-cli-production/files/cm%3A${CM_VERSION}%3Acm-linux-amd64.zip:download?alt=media` with automatic network retries (`--retry 3 --retry-delay 2 --retry-all-errors`).
   - Computes and logs the **SHA-256 digest** of both the `.zip` archive and the extracted `cm` binary for forensic audit trails, and enforces `sha256sum --check --strict` whenever `cm_sha256` is specified.

5. **Untrusted Workspace Sanitization ([Lines 281–297](https://github.com/Cotomacio/codemender-enterprise-workflows/blob/main/.github/workflows/codemender-reusable.yml#L281-L297)):**
   - Purges any pre-existing `.cm_project`, `.exploit`, or `~/.codemender` directories prior to `cm init` so a maliciously crafted repository cannot inject pre-seeded CodeMender configuration files.

6. **SARIF v2.1.0 Normalization for GitHub Code Scanning ([Lines 331–359](https://github.com/Cotomacio/codemender-enterprise-workflows/blob/main/.github/workflows/codemender-reusable.yml#L331-L359)):**
   - Normalizes `artifactLocation.uri` via `jq` to strip `${GITHUB_WORKSPACE}/` prefixes and guarantees `region.startLine >= 1`, ensuring GitHub Code Scanning anchors every alert directly onto the exact source file and line in the repository.

7. **Atomic Commits (`--no-verify`) & Native `gh pr` Pull Request Creation ([Lines 408–475](https://github.com/Cotomacio/codemender-enterprise-workflows/blob/main/.github/workflows/codemender-reusable.yml#L408-L475), [Lines 500–546](https://github.com/Cotomacio/codemender-enterprise-workflows/blob/main/.github/workflows/codemender-reusable.yml#L500-L546)):**
   - Iterates through up to `fix_limit` open findings matching `fix_severities` (prioritizing `CRITICAL` over `HIGH` and excluding `[LEGACY / UNTOUCHED]` delta items), sanitizing TSV fields against control-character injection.
   - Runs `cm fix <FINDING_ID> --sandbox=false --yes --bypass-warning < /dev/null`, stages only tracked modifications (`git add -u`), cleans untracked temporary files, and creates a dedicated **atomic commit** with `git commit --no-verify` (preventing untrusted `.git/hooks` from executing):
     ```text
     fix(security): remediate <Finding Title> [<Severity>]
     CodeMender Finding ID: <ID>
     ```
   - Pushes `codemender/remediate-<branch>` and creates or updates the Pull Request using the official pre-installed GitHub CLI (`gh pr create` / `gh pr edit`)—requiring **zero third-party community GitHub Actions**.

8. **Fail-Closed PR Security Gate ([Lines 299–329](https://github.com/Cotomacio/codemender-enterprise-workflows/blob/main/.github/workflows/codemender-reusable.yml#L299-L329), [Lines 548–564](https://github.com/Cotomacio/codemender-enterprise-workflows/blob/main/.github/workflows/codemender-reusable.yml#L548-L564)):**
   - Captures the true exit code of `cm find` via `${PIPESTATUS[0]}` (`scan_exit_code`).
   - When `enforce_gate: true`, the gate fails (`exit 1`) not only when open `CRITICAL`/`HIGH` findings are detected, but also if `scan_exit_code != 0` or `steps.triage.outcome != 'success'`—eliminating CWE-636 fail-open vulnerabilities during quota or network outages.

---

### Step 5: Onboarding an Application Team Repository (`team-a-payments`)

To onboard any application repository—demonstrated live in [`Cotomacio/team-a-payments`](https://github.com/Cotomacio/team-a-payments)—the application squad adds **3 declarative configuration files** to their repository.

#### 5.1 File 1: `.cmignore` (Scope & Token Optimization)
Placed at the root of the application repository ([`team-a-payments/.cmignore`](https://github.com/Cotomacio/team-a-payments/blob/main/.cmignore)) to exclude unit tests, mocks, generated protobuf/OpenAPI stubs, and internal tooling directories from AI analysis:

```gitignore
# Dependency, VCS & Local Tooling Directories
.git/
.cm_project/
.exploit/
node_modules/
vendor/
target/
build/
dist/
out/
.gradle/
.mvn/
.venv/
venv/
__pycache__/
*.sarif

# Unit / Integration Test Suites & Mock Data
**/test/**
**/tests/**
**/__tests__/**
**/__mocks__/**
**/*Test.java
**/*Tests.java
**/*IT.java
**/*_test.go
**/*_test.py
**/*.spec.ts
**/*.test.ts
**/*.spec.js
**/*.test.js
testdata/
fixtures/

# Generated Code, Protobufs & OpenAPI / Swagger Stubs
**/generated/**
**/gen/**
**/*.pb.go
**/*_pb2.py
**/*_pb2_grpc.py
openapi/
swagger/

# Database Migrations & Static Assets
migrations/
flyway/
liquibase/
public/
static/
assets/
docs/
*.min.js
*.bundle.js
*.map
# Note: Remove `*.sql` below if your repository contains PL/SQL stored procedures or dynamic SQL templates requiring security analysis.
*.sql
*.md
```

#### 5.2 File 2: `.github/workflows/codemender-monthly-async.yml` (Deep Audit + Auto-PR)
Placed in [`.github/workflows/codemender-monthly-async.yml`](https://github.com/Cotomacio/team-a-payments/blob/main/.github/workflows/codemender-monthly-async.yml). Runs asynchronously on the first Monday of each month (with automatic cron jitter) or via manual trigger (`workflow_dispatch`), performing a full `--deep` scan and opening an automated remediation PR:

```yaml
name: CodeMender — Monthly Deep Audit & Autonomous Remediation

on:
  schedule:
    - cron: '0 6 1-7 * 1'   # 06:00 UTC on the first Monday of every month (deterministic jitter applied automatically)
  workflow_dispatch:
    inputs:
      scan_mode:
        description: 'Scan mode override (deep or quick)'
        required: false
        default: 'deep'
        type: choice
        options:
          - deep
          - quick
      enable_autofix:
        description: 'Generate automated remediation PR (cm fix)'
        required: false
        default: true
        type: boolean

jobs:
  security-audit:
    permissions:
      contents: write          # Push remediation branch when enable_autofix is true
      pull-requests: write     # Open/update remediation Pull Request
      id-token: write          # Mint GCP Workload Identity Federation OIDC token
      security-events: write   # Upload SARIF v2.1.0 to GitHub Code Scanning
      actions: read            # Required by github/codeql-action/upload-sarif in private repos
    uses: Cotomacio/codemender-enterprise-workflows/.github/workflows/codemender-reusable.yml@main
    with:
      gcp_project_id: ${{ vars.GCP_QUOTA_PROJECT }}
      gcp_wif_provider: ${{ vars.GCP_WIF_PROVIDER }}
      gcp_sa_email: ${{ vars.GCP_SA_EMAIL }}
      gcp_telemetry_bucket: ${{ vars.GCP_TELEMETRY_BUCKET }}
      scan_mode: ${{ inputs.scan_mode || 'deep' }}
      enable_autofix: ${{ inputs.enable_autofix != false }}
      fix_severities: 'CRITICAL,HIGH'
      fix_limit: '5'
      schedule_jitter_max_seconds: '300'
      enforce_gate: false
      upload_sarif: true
```

#### 5.3 File 3: `.github/workflows/codemender-pr-gate.yml` (Fast PR Diff Gate — Read-Only)
Placed in [`.github/workflows/codemender-pr-gate.yml`](https://github.com/Cotomacio/team-a-payments/blob/main/.github/workflows/codemender-pr-gate.yml). Runs on every Pull Request targeting `main` or `master` with **strict read-only repository permissions (`contents: read`, `pull-requests: read`)**, using `--diff` mode to analyze only modified code and its 1-hop callers/callees and blocking the merge (`enforce_gate: true`, fail-closed) if new `CRITICAL` or `HIGH` vulnerabilities are introduced:

```yaml
name: CodeMender — Pull Request Security Gate (Diff Mode)

on:
  pull_request:
    branches:
      - main
      - master

jobs:
  pr-security-gate:
    permissions:
      contents: read           # Read-only checkout for PR delta scan (no branch write access)
      pull-requests: read      # Read-only PR metadata
      id-token: write          # Mint GCP Workload Identity Federation OIDC token
      security-events: write   # Upload SARIF v2.1.0 annotations to the Pull Request
      actions: read            # Required by github/codeql-action/upload-sarif in private repos
    uses: Cotomacio/codemender-enterprise-workflows/.github/workflows/codemender-reusable.yml@main
    with:
      gcp_project_id: ${{ vars.GCP_QUOTA_PROJECT }}
      gcp_wif_provider: ${{ vars.GCP_WIF_PROVIDER }}
      gcp_sa_email: ${{ vars.GCP_SA_EMAIL }}
      gcp_telemetry_bucket: ${{ vars.GCP_TELEMETRY_BUCKET }}
      scan_mode: 'diff'
      enable_autofix: false
      fix_severities: 'CRITICAL,HIGH'
      enforce_gate: true
      upload_sarif: true
```

---

### Step 6: End-to-End Execution & Live Verification Walkthrough (`team-a-payments`)

To validate the entire architecture end-to-end, we created [`Cotomacio/team-a-payments`](https://github.com/Cotomacio/team-a-payments) containing a sample microservice ([`app.py`](https://github.com/Cotomacio/team-a-payments/blob/main/app.py)) with two intentional `HIGH`-severity vulnerabilities:
1. **SQL Injection (`CWE-89`)** in `/payments/lookup` (raw string interpolation into `cur.execute()`).
2. **OS Command Injection (`CWE-78`)** in `/payments/export-receipt` (`subprocess.check_output(..., shell=True)` with unvalidated user input).

#### 6.1 Pipeline Execution (`Workflow Run #40435451718`)
🔗 **Live Run URL:** [`https://github.com/Cotomacio/team-a-payments/actions/runs/40435451718`](https://github.com/Cotomacio/team-a-payments/actions/runs/40435451718)

| Pipeline Step | Execution Result | Duration |
| :--- | :---: | :---: |
| `Checkout Repository` | ✅ Success | `2s` |
| `Validate Required Inputs` | ✅ Success | `1s` |
| `Authenticate to Google Cloud (WIF)` | ✅ Keyless OIDC token minted for `codemender-ci@codemender-latam.iam.gserviceaccount.com` | `2s` |
| `Protect WIF Credentials Outside Git Workspace` | ✅ Moved ADC credentials to `$RUNNER_TEMP/gcp-creds.json` | `1s` |
| `Download & Install CodeMender CLI` | ✅ Installed `cm` (`v0.16.6`) from Artifact Registry | `2s` |
| `Initialize Stateless CodeMender Workspace` | ✅ `cm init` + `cm health --strict` passed | `19s` |
| `Execute CodeMender Scan (cm find)` | ✅ Found **2 HIGH** vulnerabilities (`SQLINY4A`, `CMDI3413`) | `7m 46s` |
| `Export Reports, Token Telemetry & Triage Findings` | ✅ Normalized SARIF & generated Job Summary table | `5s` |
| `Upload SARIF v2.1.0 to GitHub Code Scanning` | ✅ Uploaded SARIF (`category: codemender-deep`) | `10s` |
| `Autonomous Remediation (cm fix -> Atomic Commits)` | ✅ Generated & verified 2 patches (`2/2` fixed) | `12m 11s` |
| `Archive Telemetry & SARIF to GCS` | ✅ Exported to `gs://codemender-latam-codemender-telemetry/...` | `5s` |
| `Upload Reports as Workflow Artifacts` | ✅ Attached `codemender-reports-deep-40435451718` | `2s` |
| `Open Autonomous Remediation Pull Request` | ✅ Opened [PR #1](https://github.com/Cotomacio/team-a-payments/pull/1) on branch `codemender/remediate-main` | `5s` |

#### 6.2 Output 1: Native GitHub Code Scanning Alerts (SARIF v2.1.0)
Immediately after `Upload SARIF v2.1.0 to GitHub Code Scanning`, both vulnerabilities appeared natively in the **Security → Code scanning** tab of `team-a-payments`:
- 🔗 **[Alert #1 — OS Command Injection in Receipt Export (`CWE-78`, High)](https://github.com/Cotomacio/team-a-payments/security/code-scanning/1)** (`app.py:42`)
- 🔗 **[Alert #2 — SQL Injection in Payment Lookup (`CWE-89`, High)](https://github.com/Cotomacio/team-a-payments/security/code-scanning/2)** (`app.py:25`)

#### 6.3 Output 2: Automated Remediation Pull Request with Atomic Commits
CodeMender opened **[Pull Request #1: `fix(security): CodeMender autonomous remediation (2 finding(s))`](https://github.com/Cotomacio/team-a-payments/pull/1)** containing **2 separate atomic commits**:
1. **Commit [`c8aa44a`](https://github.com/Cotomacio/team-a-payments/pull/1/commits/c8aa44a428c4565e14217371784bd5563b819749) (`SQLINY4A`):** Replaced string formatting with parameterized SQL queries (`WHERE customer_id = ?`, `(customer_id,)`).
2. **Commit [`97dfde6`](https://github.com/Cotomacio/team-a-payments/pull/1/commits/97dfde69fd77de86d94f70360a0d2f0eb99e2d8d) (`CMDI3413`):** Removed `shell=True`, removed `/bin/sh -c` interpolation, and enforced strict `^[a-zA-Z0-9_-]+$` validation on `invoice_id`.

#### 6.4 Output 3: Centralized FinOps & Security Telemetry in Cloud Storage
Every execution archives three immutable files to Google Cloud Storage partitioned by organization, repository, date, and run ID:

```text
gs://codemender-latam-codemender-telemetry/
└── codemender-telemetry/
    └── Cotomacio/
        └── team-a-payments/
            └── 2026/10/27/
                └── 20261027T021200Z-40435451718/
                    ├── codemender.sarif      # Full SARIF v2.1.0 report for central ASPM / SIEM ingestion
                    ├── findings-open.json    # Structured JSON snapshot of findings detected
                    └── stats.json            # Vertex AI Gemini token consumption & latency metrics
```

Real `stats.json` captured from Run `#40435451718` (`find` + `fix` across 2 vulnerabilities):
```json
{
  "by_command": [
    {
      "command": "find",
      "duration_ms": 465370,
      "model": "gemini-3.1-pro-preview",
      "tokens": {
        "cached": 1353620,
        "input": 1528408,
        "output": 49164,
        "thinking": 35785,
        "total": 1577572
      }
    },
    {
      "command": "fix",
      "duration_ms": 727536,
      "model": "gemini-3.1-pro-preview",
      "tokens": {
        "cached": 1767330,
        "input": 2033630,
        "output": 42159,
        "thinking": 28759,
        "total": 2075789
      }
    }
  ],
  "totals": {
    "duration_ms": 1192906,
    "tokens": {
      "cached": 3120950,
      "input": 3562038,
      "output": 91323,
      "thinking": 64544,
      "total": 3653361
    }
  }
}
```
> [!TIP]
> **FinOps Insight — 87.6% Prompt Caching Efficiency:**  
> Notice that out of `3,562,038` input tokens processed across `cm find` and `cm fix`, **`3,120,950` tokens (87.6%) were served from Vertex AI Context Cache (`cached`)**, dramatically reducing per-scan token cost. Platform teams can mount a BigQuery External Table over `gs://<BUCKET>/codemender-telemetry/*/*/*/*/*/stats.json` to build real-time Looker Studio FinOps chargeback dashboards by repository and business unit.

---

## 3. Regulated Enterprise Governance, Compliance & Security Hardening Reference

This section provides the control documentation required by CISOs, Cloud Risk Officers, and External Auditors in regulated industries (**Banking, Fintech, Healthcare, Insurance, Government**).

### 3.1 Regulatory & Compliance Framework Mapping

| Framework / Standard | Control ID | Requirement Summary | How This Architecture Satisfies the Control |
| :--- | :--- | :--- | :--- |
| **PCI-DSS v4.0** | **Req 6.3.2 & 6.5** | Inventory bespoke/custom software, scan for vulnerabilities, and manage all code changes via controlled change processes. | Automated `--deep` and `--diff` scans produce SARIF v2.1.0 alerts; patches are delivered exclusively as atomic commits inside reviewable Pull Requests. |
| **PCI-DSS v4.0** | **Req 10.5.1 & 10.7** | Retain audit logs for at least 12 months and protect logs so they cannot be altered or deleted. | GCS bucket enforces `--retention-period=365d` (WORM), `--public-access-prevention`, `--no-clobber`, and `roles/storage.objectCreator` (no delete/overwrite permissions). |
| **SOC 2 Type II** | **CC6.1 & CC6.6** | Logical access security & boundary protection using least-privilege ephemeral credentials. | Zero long-lived keys; WIF OIDC provider enforces both `assertion.repository_owner` and `assertion.job_workflow_ref` binding; PR gates run with `contents: read`. |
| **SOC 2 Type II** | **CC7.2 & CC8.1** | Security event monitoring & authorized change management before production deployment. | Fail-closed PR security gates (`enforce_gate: true`) block vulnerable merges; `cm fix` atomic commits require human PR approval before merge. |
| **ISO/IEC 27001:2022** | **A.8.9, A.8.15, A.8.25, A.8.28** | Configuration management, immutable logging, secure SDLC rules, and secure coding verification. | Centrally governed reusable workflow eliminates configuration drift across 100+ repositories; all inputs sanitized against CWE-78 script injection. |
| **NIST SP 800-218 (SSDF v1.1)** | **PW.4, PW.7, PO.3, RV.1** | Secure software supply chain, automated human-reviewed code analysis, and vulnerability remediation. | All GitHub/Google actions pinned to 40-char commit SHAs; zero third-party community actions; `cm` binary SHA-256 logged & verified (`cm_sha256`). |
| **CIS GitHub Benchmark v1.0** | **4.2.3 & 4.2.5** | Pin all actions to full-length commit SHAs; restrict `GITHUB_TOKEN` to minimum required permissions. | 40-char SHA pinning in `codemender-reusable.yml`; explicit least-privilege `permissions:` blocks in caller templates; zero `${{ }}` macro expansion in `run:`. |
| **SEC Rule 17a-4 / DORA / BACEN 4.893** | **WORM & Operational Resilience** | Immutable audit preservation and protection against cloud service quota exhaustion. | GCS WORM retention policy + deterministic per-repository cron jitter (`schedule_jitter_max_seconds`) prevents Vertex AI `429` thundering-herd outages. |

---

### 3.2 Supply-Chain Hardening: Immutable Workflow Versioning (`@v1.0.0` vs `@main`)

In the demo repository (`team-a-payments`), caller workflows reference `@main` for rapid iteration. In **regulated production environments**, Platform teams should publish signed Git tags/releases on `codemender-enterprise-workflows` (e.g., `v1.0.0`) or pin to a 40-character commit SHA:

```yaml
# Recommended for Regulated Production Repositories:
uses: Cotomacio/codemender-enterprise-workflows/.github/workflows/codemender-reusable.yml@v1.0.0
```
Additionally, Platform teams can pass `cm_version` (e.g., `'0.16.6'`) and `cm_sha256` (`'<64-char-hex-digest>'`) so every runner cryptographically verifies the exact CodeMender CLI archive before extraction.

---

### 3.3 Data Privacy, Vertex AI Zero Data Retention, Regional Residency & VPC Service Controls

Financial institutions and healthcare organizations frequently require strict guarantees regarding source code confidentiality when invoking cloud AI models:

1. **Google Cloud Data Governance Guarantee:** Under Google Cloud's Enterprise Data Governance terms for Vertex AI, customer source code, prompts, and generated patches sent to Vertex AI / Gemini models **are never used to train Google foundation models**.
2. **Zero Data Retention & Abuse Monitoring Exemption:** Regulated customers can enable **Zero Data Retention (ZDR)** and opt out of human abuse review caching on their Google Cloud project (`codemender-latam`) so prompts and code context are processed strictly in memory.
3. **Regional Data Residency (`cm_location`):** If regulatory mandates (such as GDPR in the EU or BACEN in Brazil) require regional API endpoints rather than `global`, pass `cm_location: 'us-central1'` or `cm_location: 'europe-west1'` to the reusable workflow and set `BUCKET_LOCATION` to the matching region when running `setup-enterprise-wif-and-gcs.sh`.
4. **VPC Service Controls (VPC-SC) & Self-Hosted Runners:**
   - For banks enforcing **VPC Service Controls** perimeters around `aiplatform.googleapis.com` and `storage.googleapis.com`, deploy **GitHub Actions Runner Controller (ARC)** on internal Google Kubernetes Engine (GKE) clusters inside the authorized VPC network.
   - Configure an ingress/egress policy or Private Google Access (`private.googleapis.com`) so all CodeMender traffic remains entirely on Google's private backbone.

---

### 3.4 Untrusted Code Execution Isolation & Ephemeral Runner Hardening

During `cm find` and `cm fix`, CodeMender may invoke build verification or test commands configured in the repository. To prevent untrusted code in a Pull Request from compromising credentials or persisting across runs:
1. **Ephemeral VM Isolation:** Each GitHub-hosted `ubuntu-24.04` job (or ephemeral GKE ARC pod with `gVisor` / Kata Containers isolation) runs in a single-use virtual environment destroyed immediately after the job completes.
2. **Pre-Init Workspace Sanitization:** Before running `cm init`, the reusable workflow executes `rm -rf .cm_project .exploit ~/.codemender` ([Line 285](https://github.com/Cotomacio/codemender-enterprise-workflows/blob/main/.github/workflows/codemender-reusable.yml#L285)), ensuring a repository cannot pre-seed malicious `.cm_project` configurations.
3. **Git Hook Bypass (`--no-verify`):** Atomic commits use `git commit --no-verify` ([Line 453](https://github.com/Cotomacio/codemender-enterprise-workflows/blob/main/.github/workflows/codemender-reusable.yml#L453)) so untrusted scripts inside `.git/hooks/` are never triggered.
4. **Post-Run Credential Shredding:** The final workflow step (`Shred Temporary WIF Credentials`, `if: ${{ always() }}`, [Lines 566–569](https://github.com/Cotomacio/codemender-enterprise-workflows/blob/main/.github/workflows/codemender-reusable.yml#L566-L569)) deletes `$RUNNER_TEMP/gcp-creds.json` and `~/.config/gcloud/application_default_credentials.json`.

---

### 3.5 GitHub Rulesets, Required Status Checks & Signed Commits (`secrets.pr_token`)

In mature enterprises where `main` is protected by **GitHub Repository Rulesets** requiring status checks (unit tests, SAST) to pass before merging:
- **Known GitHub Actions Platform Behavior:** By default, branches pushed and Pull Requests opened using the built-in `secrets.GITHUB_TOKEN` **do not trigger downstream `on: pull_request` workflows** (a GitHub anti-recursion safeguard).
- **Enterprise Solution Built Into `codemender-reusable.yml`:** The reusable workflow supports an optional `secrets.pr_token` secret ([Lines 144–146](https://github.com/Cotomacio/codemender-enterprise-workflows/blob/main/.github/workflows/codemender-reusable.yml#L144-L146), [Line 503](https://github.com/Cotomacio/codemender-enterprise-workflows/blob/main/.github/workflows/codemender-reusable.yml#L503)). Organizations can pass a **GitHub App Installation Token** (generated via `actions/create-github-app-token` or stored as an Org secret) via `secrets: pr_token: ${{ secrets.CODEMENDER_APP_TOKEN }}`. Pull Requests opened with a GitHub App token automatically trigger all required CI status checks on `codemender/remediate-main`.

---

## 4. Enterprise Rollout Checklist for Customers

- [ ] **1. GCP Project & APIs:** Select or create a dedicated GCP project for CodeMender quota and run [`scripts/setup-enterprise-wif-and-gcs.sh`](https://github.com/Cotomacio/codemender-enterprise-workflows/blob/main/scripts/setup-enterprise-wif-and-gcs.sh) with `ENFORCE_JOB_WORKFLOW_REF=true` and `RETENTION_PERIOD=365d`.
- [ ] **2. Central Workflow Repo:** Fork or copy [`Cotomacio/codemender-enterprise-workflows`](https://github.com/Cotomacio/codemender-enterprise-workflows) into your GitHub Organization, tag an immutable release (`v1.0.0`), and enable **Actions → Access → Accessible from repositories in the organization**.
- [ ] **3. Organization Variables:** Configure `GCP_QUOTA_PROJECT`, `GCP_WIF_PROVIDER`, `GCP_SA_EMAIL`, and `GCP_TELEMETRY_BUCKET` in GitHub Organization Variables.
- [ ] **4. Pilot Onboarding:** Copy [`.cmignore`](https://github.com/Cotomacio/codemender-enterprise-workflows/blob/main/examples/caller-repo/.cmignore), [`codemender-monthly-async.yml`](https://github.com/Cotomacio/codemender-enterprise-workflows/blob/main/examples/caller-repo/.github/workflows/codemender-monthly-async.yml), and [`codemender-pr-gate.yml`](https://github.com/Cotomacio/codemender-enterprise-workflows/blob/main/examples/caller-repo/.github/workflows/codemender-pr-gate.yml) into a pilot repository (like [`Cotomacio/team-a-payments`](https://github.com/Cotomacio/team-a-payments)) and trigger a `workflow_dispatch` run.
- [ ] **5. Organization-Wide Scale:** Roll out the 3 template files across all 100+ repositories via an automated onboarding PR or GitHub repository template.
