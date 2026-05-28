# LLM API Pool Solution

本方案为中国客户设计一套面向 Claude/GPT 等海外闭源模型的多渠道 API 供应池。目标是在企业合规、采购可控、日志可审计、容量可扩展的前提下，为约 1000 名员工提供稳定的模型访问能力。

## 方案文件

1. `llm-api-pool-solution.md`：主解决方案文档（LiteLLM + Azure Foundry 模型 API 池），Markdown 格式，中文。
2. `github-copilot-solution.md`：GitHub Copilot Vibe Coding 方案文档（Harness + 模型 API 完整方案）。
3. `scripts/create-subscriptions.sh`：第一阶段脚本，创建 Azure 订阅并输出参数 CSV。
4. `scripts/deploy-models.sh`：第二阶段脚本，基于 CSV 部署 Foundry 资源和模型端点。
5. `scripts/delete-resources.sh`：清理脚本，删除资源组并清除软删除状态。
6. `scripts/test-endpoints.sh`：端点连通性验证脚本。
7. `config/litellm-config.example.yaml`：LiteLLM 示例配置。
8. `.vscode/mcp.example.json`：VS Code / GitHub Copilot 本地 MCP 示例配置。
