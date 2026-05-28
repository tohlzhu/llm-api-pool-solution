# Agent Instructions

## Project Overview

This repository is a Chinese enterprise solution package for a high-availability Claude/GPT API supply pool. The primary artifact is [llm-api-pool-solution.md](llm-api-pool-solution.md); supporting examples live in [config/litellm-config.example.yaml](config/litellm-config.example.yaml), [scripts/](scripts/) (create-subscriptions, deploy-models, delete-resources, test-endpoints), [.vscode/mcp.example.json](.vscode/mcp.example.json), and [github-copilot-solution.md](github-copilot-solution.md).

## Working Rules

- Keep the main solution document in Chinese, with enterprise architecture tone, numbered sections, tables where useful, and explicit caveats for compliance, quota, Marketplace, region, and customer-tenant validation.
- Do not copy large blocks from existing docs into new guidance. Link to [README.md](README.md), [llm-api-pool-solution.md](llm-api-pool-solution.md), or the relevant example file instead.
- Never add real tenant IDs, subscription IDs, API keys, tokens, customer names, endpoints, or secrets. Use placeholders, Bash environment variables, LiteLLM `os.environ/NAME`, and Azure Key Vault references.
- GitHub Copilot is the recommended Vibe Coding solution (described in github-copilot-solution.md), not a LiteLLM backend or unattended service-side API pool.
- Community MCP packages are examples until reviewed. Preserve source/dependency review, least privilege, local employee authorization, and human confirmation for write actions.

## File Conventions

- Markdown files are the product surface. Update related sections consistently instead of appending disconnected notes.
- LiteLLM examples should use `model_list`, per-deployment `tpm`, `rpm`, `max_parallel_requests`, `model_info`, Redis-backed router state, fallbacks, and audit/cost controls.
- Bash examples should remain Linux/Azure CLI oriented, start with `#!/usr/bin/env bash` and `set -euo pipefail`, use helper functions for required commands/env vars, and write errors/status to stderr.
- JSON examples under [.vscode/](.vscode/) should remain local developer configuration examples and must not contain comments unless the target parser supports them.

## Validation

- There is no repository build or test suite. Use focused validation for the files touched: editor diagnostics for Markdown/YAML/JSON, shell syntax checks for Bash, and manual review for placeholder-only secrets.
- For script changes, run `bash -n scripts/*.sh` as the first executable check.
- For configuration changes, verify YAML/JSON syntax and confirm all secret-like values are placeholders or environment references.

## Current Work Queue

[todo.md](todo.md) tracks pending solution enhancements. Do not implement items from it unless the user asks; when asked, update the listed output files only as needed.
