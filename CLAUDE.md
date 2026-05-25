# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Summary

This is a solution design repository (not a runnable application) for a Chinese enterprise LLM API supply pool. The primary deliverable is `llm-api-pool-solution.md` — a Chinese-language architecture document describing a multi-subscription Azure Foundry + LiteLLM gateway setup serving ~1000 employees with Claude and GPT models.

Supporting artifacts: `scripts/create-foundry-pool.sh` (Azure CLI automation), `config/litellm-config.example.yaml` (LiteLLM proxy config), `.vscode/mcp.example.json` (VS Code MCP setup).

## Validation Commands

There is no build system or test suite. Validate touched files individually:

```bash
# Bash script syntax check
bash -n scripts/create-foundry-pool.sh

# YAML syntax check (requires python3)
python3 -c "import yaml; yaml.safe_load(open('config/litellm-config.example.yaml'))"

# JSON syntax check
python3 -c "import json; json.load(open('.vscode/mcp.example.json'))"
```

## Writing Rules

- **Language**: Main solution document and README are in Chinese with enterprise architecture tone. Use numbered sections, tables, and explicit caveats for compliance/quota/region constraints.
- **No secrets**: Never add real tenant IDs, subscription IDs, API keys, tokens, or endpoints. Use Bash env vars, `os.environ/NAME` (LiteLLM syntax), or Key Vault references.
- **Copilot positioning**: GitHub Copilot is an IDE/CLI fallback only — never a LiteLLM backend or unattended API source.
- **MCP servers**: Community MCP packages are examples pending review. Preserve local-auth-first, least-privilege, human-confirmation-for-writes principles.
- **Markdown structure**: Update related sections consistently rather than appending disconnected notes. Link to other repo files instead of duplicating content.
- **LiteLLM config style**: Use `model_list` with per-deployment `tpm`, `rpm`, `max_parallel_requests`, `model_info`, Redis-backed router state, fallbacks, and audit controls.
- **Bash script style**: Start with `#!/usr/bin/env bash` and `set -euo pipefail`. Use helper functions for required commands/env vars. Write status to stderr.

## Architecture at a Glance

```
5-layer supply model:
  L1: Microsoft Foundry (primary) — Claude + GPT across 10 Azure subscriptions
  L2: Multi-subscription Claude pool — LiteLLM load-balances across all Foundry endpoints
  L3: GPT pool — parallel first-class model pool + Claude fallback target
  L4: Partner Vertex AI Claude — cross-cloud backup via Google Vertex
  L5: GitHub Copilot — IDE/CLI human-interactive fallback only

Horizontal isolation:
  Batch pool: 5 additional subscriptions for scheduled/repetitive workloads
  Separated in LiteLLM as batch-* model groups with dedicated keys and budgets

Gateway: LiteLLM on AKS with Redis (shared router state), PostgreSQL (spend/logs),
         Key Vault (secrets), and observability stack (Langfuse/OTel/Sentinel)
```

## Work Queue

`todo.md` tracks pending enhancements. Do not implement items from it unless explicitly asked.
