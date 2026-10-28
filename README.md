# 🛡️ CodeMender Enterprise Reusable Workflows

Arquitetura de referência **Enterprise-Ready (100% Stateless Runner)** para execução do **Google Cloud CodeMender (`cm`)** em escala (100+ repositórios) via **GitHub Actions Reusable Workflows (`workflow_call`)**.

Este repositório centraliza toda a lógica de autenticação *keyless* (WIF), verificação de saúde (`cm health`), execução do *scan* (`deep`, `diff` ou `quick`), publicação nativa de **SARIF v2.1.0** no GitHub Code Scanning / ASPM, criação automática de **Pull Requests de Remediação (`cm fix`)** com commits atômicos por vulnerabilidade e exportação opcional *append-only* de telemetria de tokens (`cm stats --json`).

---

## 🏗️ Arquitetura em Escala (100% Stateless Runner + SARIF + Auto-PR)

Seguindo as melhores práticas de engenharia DevSecOps, **os runners do GitHub Actions operam de forma 100% *stateless*** (sem sincronizar ou depender do arquivo SQLite local `state.db` entre execuções):
* **Ciclo de Vida e Deduplicação de Vulnerabilidades (Para AppSec):** Gerenciado via exportação **SARIF v2.1.0** diretamente no **GitHub Code Scanning** (ou na ferramenta ASPM central, como DefectDojo / Wiz), evitando *race conditions* de SQLite e silos de linha de comando.
* **Entrega da Correção (Para Desenvolvedores):** Na mesma execução efêmera, o `cm fix` gera o *patch* e abre um **Pull Request** com 1 commit atômico por vulnerabilidade corrigida.

---

## 📂 Estrutura deste Repositório

| Arquivo | Descrição |
| :--- | :--- |
| [`.github/workflows/codemender-reusable.yml`](.github/workflows/codemender-reusable.yml) | **Workflow Central Reutilizável (`workflow_call`)**: 100% *stateless* e autocontido (sem scripts Python externos e sem dependência de persistência de `state.db`), usa `jq` nativo, protege credenciais WIF contra `git clean -fd`, publica SARIF v2.1.0 e abre PRs com 1 commit por vulnerabilidade corrigida. |
| [`examples/caller-repo/.github/workflows/codemender-monthly-async.yml`](examples/caller-repo/.github/workflows/codemender-monthly-async.yml) | **Template de Pipeline Assíncrona (Mensal / Sob Demanda)**: Arquivo de 25 linhas que cada repositório copia para rodar o `--deep` scan agendado e receber PRs automáticos de correção. |
| [`examples/caller-repo/.github/workflows/codemender-pr-gate.yml`](examples/caller-repo/.github/workflows/codemender-pr-gate.yml) | **Template de Gate de Pull Request (`--diff`)**: Analisa apenas os trechos alterados no PR e seus dependentes diretos (*1-hop callers/callees*) em menos de 2 minutos. |
| [`examples/caller-repo/.cmignore`](examples/caller-repo/.cmignore) | **Template `.cmignore` Enterprise**: Exclui pastas de testes, mocks, código gerado (Protobuf/OpenAPI) e assets estáticos para otimizar o tempo de scan e o consumo de tokens. |
| [`scripts/setup-enterprise-wif-and-gcs.sh`](scripts/setup-enterprise-wif-and-gcs.sh) | **Script de Bootstrap GCP**: Configura Service Account, WIF Pool no nível da Organização do GitHub e o Bucket GCS opcional para telemetria FinOps. |
| [`docs/ENTERPRISE_ARCHITECTURE_GUIDE.md`](docs/ENTERPRISE_ARCHITECTURE_GUIDE.md) | **Enterprise Architecture & Customer Onboarding Guide**: Documentação completa passo a passo da arquitetura Hub-and-Spoke, modelo de consumo por squad, FinOps e verificação end-to-end. |
