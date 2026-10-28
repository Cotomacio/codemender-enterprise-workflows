# 🛡️ CodeMender Enterprise Reusable Workflows

Arquitetura de referência **Enterprise-Ready & Regulated-Industry Hardened (100% Stateless Runner)** para execução do **Google Cloud CodeMender (`cm`)** em escala (100+ a 1.000+ repositórios) via **GitHub Actions Reusable Workflows (`workflow_call`)**, validada contra **PCI-DSS v4.0, SOC 2 Type II, ISO/IEC 27001:2022, NIST SP 800-218 (SSDF v1.1), CIS GitHub/GCP Benchmarks e SLSA Build L2**.

Este repositório centraliza toda a lógica de autenticação *keyless* Zero-Trust (WIF com binding de `assertion.job_workflow_ref`), verificação de integridade SHA-256 do binário `cm`, verificação de saúde (`cm health`), execução do *scan* (`deep`, `diff` ou `quick`) com *cron jitter* determinístico, publicação nativa de **SARIF v2.1.0** no GitHub Code Scanning / ASPM, criação nativa de **Pull Requests de Remediação (`cm fix` + `gh pr`)** com commits atômicos por vulnerabilidade, Security Gate **Fail-Closed**, e exportação *append-only* imutável (WORM) de telemetria de tokens (`cm stats --json`) e relatórios SARIF no Cloud Storage.

---

## 🏗️ Arquitetura em Escala (100% Stateless Runner + Zero-Trust WIF + SARIF + Auto-PR)

Seguindo as práticas de engenharia DevSecOps para empresas altamente reguladas (bancos, fintechs, saúde, telecom), **os runners do GitHub Actions operam de forma 100% *stateless*** (sem sincronizar ou depender do arquivo SQLite local `state.db` entre execuções):
* **Cadeia de Suprimentos Imutável (Supply-Chain Pinning):** Todas as Actions oficiais do GitHub e Google são fixadas por hash SHA de 40 caracteres, sem dependência de Actions comunitárias de terceiros, e o binário `cm` tem seu hash SHA-256 auditado (e opcionalmente validado via `cm_sha256`).
* **Zero-Trust WIF (`job_workflow_ref` Binding):** O provedor OIDC no Google Cloud STS exige que o token venha exclusivamente da execução deste workflow central reutilizável (`codemender-reusable.yml`), impedindo que workflows arbitrários em branches de desenvolvedores personifiquem a Service Account.
* **Trilha de Auditoria Imutável (WORM / Append-Only):** O bucket GCS utiliza `roles/storage.objectCreator` + `--no-clobber` + retenção WORM (`--retention-period=365d`) e prevenção de acesso público, garantindo que nenhum runner possa sobrescrever ou apagar relatórios históricos de auditoria (PCI-DSS Req 10.5.1 / SOC 2 CC7.2 / SEC Rule 17a-4).
* **Ciclo de Vida e Deduplicação de Vulnerabilidades (Para AppSec):** Gerenciado via exportação **SARIF v2.1.0** diretamente no **GitHub Code Scanning** (ou na ferramenta ASPM central, como DefectDojo / Wiz).
* **Entrega da Correção (Para Desenvolvedores):** Na mesma execução efêmera, o `cm fix` gera o *patch* e o GitHub CLI (`gh pr`) abre um **Pull Request** com 1 commit atômico (`--no-verify`) por vulnerabilidade corrigida, com suporte a GitHub App Tokens (`secrets.pr_token`) para disparar esteiras de CI obrigatórias.

---

## 📂 Estrutura deste Repositório

| Arquivo | Descrição |
| :--- | :--- |
| [`.github/workflows/codemender-reusable.yml`](.github/workflows/codemender-reusable.yml) | **Workflow Central Reutilizável (`workflow_call`)**: 100% *stateless*, *fail-closed*, livre de injeção de script (`${{ }}`), Actions fixadas por SHA de 40 caracteres, *cron jitter* determinístico, proteção e destruição pós-execução de credenciais WIF, publicação SARIF v2.1.0 e abertura nativa de PRs com 1 commit atômico por vulnerabilidade corrigida. |
| [`examples/caller-repo/.github/workflows/codemender-monthly-async.yml`](examples/caller-repo/.github/workflows/codemender-monthly-async.yml) | **Template de Pipeline Assíncrona (Mensal / Sob Demanda)**: Template com permissões explícitas de privilégio mínimo que cada repositório copia para rodar o `--deep` scan agendado e receber PRs automáticos de correção. |
| [`examples/caller-repo/.github/workflows/codemender-pr-gate.yml`](examples/caller-repo/.github/workflows/codemender-pr-gate.yml) | **Template de Gate de Pull Request (`--diff`, Read-Only)**: Opera com `contents: read` e `pull-requests: read`, analisando apenas os trechos alterados no PR e seus dependentes diretos (*1-hop callers/callees*) em modo *fail-closed*. |
| [`examples/caller-repo/.cmignore`](examples/caller-repo/.cmignore) | **Template `.cmignore` Enterprise**: Exclui pastas de testes, mocks, código gerado (Protobuf/OpenAPI), diretórios internos (`.cm_project/`, `.exploit/`) e assets estáticos para otimizar o tempo de scan e o consumo de tokens. |
| [`scripts/setup-enterprise-wif-and-gcs.sh`](scripts/setup-enterprise-wif-and-gcs.sh) | **Script de Bootstrap GCP (Zero-Trust & WORM)**: Configura Service Account, WIF Pool com validação de `assertion.job_workflow_ref` e Bucket GCS *append-only* (`roles/storage.objectCreator`, `--public-access-prevention`, retenção WORM e suporte a CMEK). |
| [`docs/ENTERPRISE_ARCHITECTURE_GUIDE.md`](docs/ENTERPRISE_ARCHITECTURE_GUIDE.md) | **Enterprise Architecture, Compliance & Customer Onboarding Guide**: Documentação completa passo a passo da arquitetura Hub-and-Spoke, modelo de consumo por squad, FinOps, verificação end-to-end e controles para indústrias reguladas (PCI-DSS v4.0, SOC 2, ISO 27001, NIST SSDF, SLSA). |
