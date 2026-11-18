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

## 增量部署单个模型

`scripts/deploy-single-model.py` 使用现有订阅 CSV，但不按 `model_type` 选择模型。部署参数全部来自 `--model-info`，依次为部署名、模型名、版本、格式、SKU 名、可选的 SKU 容量；容量直接使用 Azure SKU 单位，不进行 TPM 换算。需要 Python 3 和已登录的 Azure CLI。

```bash
python3 scripts/deploy-single-model.py \
  --input ./generated/subscriptions-test1.csv \
  --resource-group rg-foundry \
  --account-name fdry-demo-sub1 \
  --project-name proj-demo-sub1 \
  --direct \
  --model-info "gpt-6-luna|gpt-6-luna|2026-09-22|OpenAI|GlobalStandard|1000000"
```

默认沿用 `deploy-models.sh` 的命名规则：`rg-foundry`、`fdry-<subscription_name>`、`proj-<subscription_name>`。上述名称参数可覆盖整批目标，也可在 CSV 中添加 `resource_group,account_name,project_name` 列逐订阅指定；命令行优先。部署与原脚本一样位于 Foundry account 下，脚本会先确保 project 存在。已有中间资源会复用；同名部署会比较模型名、版本、格式、SKU 和容量，有差异则更新并等待验证成功，没有差异则跳过。

`--direct` 跳过 provider 注册及 resource group、Foundry account、project 的所有检查和创建，直接查询目标 deployment。目标基础资源必须已存在，且 CSV 的 `location` 必须填写现有 Foundry account 所在区域；该模式不使用 `prefix`，因此 CSV 可省略该列。

容量按每个订阅、区域、模型和 SKU 的实际 quota 单独计算，指标名称来自 Azure 模型元数据，不内置模型配额映射。显式容量超出可用额度时自动下调；省略第六个字段（如 `--model-info "gpt-6-luna|gpt-6-luna|2026-09-22|OpenAI|GlobalStandard"`），或保留末尾 `|` 但不填容量时，使用全部可用额度。更新时，可用额度为 `quota limit - 当前总用量 + 当前部署在同一 quota 池占用的容量`，不会因 quota 已被该部署占满而错误缩容；不同配额池不加回旧容量。最终容量同时遵守 SKU 的最大值、步长和允许值限制。没有可部署额度或无法可靠查询 quota 时，该订阅报错且不修改 deployment；并发导致配额变化时会刷新并重试一次。

`--deployment-properties 'JSON'` 可补充模型来源、`versionUpgradeOption`、`raiPolicyName`、`modelProviderData` 等可写部署属性，显式指定的属性也参与一致性检查。例如 `--deployment-properties '{"model":{"source":"<source>"},"versionUpgradeOption":"NoAutoUpgrade"}'`。Anthropic 必填组织信息优先使用该 JSON，其次使用 CSV 的 `anthropic-*` 列，缺失时尝试按原脚本规则查询租户。更新时保留未指定的已有可写设置，不自动删除或重建资源；遇到软删除的同名 account 会提示先恢复或显式清除。

先用 `--dry-run` 查看计划，非交互执行使用 `--force`。单个订阅失败不会阻断后续订阅，但最终退出码非零。新脚本只输出执行摘要，不覆盖原脚本生成的端点清单。

增加 `--delete` 可按订阅批量删除指定 deployment：存在则删除并等待确认不存在，不存在则跳过。删除模式自动跳过 provider、resource group、account、project 和 quota 检查，不会创建或删除任何基础资源，无需再加 `--direct`。`--model-info` 可只填部署名，也兼容原有完整格式，但只按第一个字段 `deployment_name` 定位，不比较其他模型参数。删除仍要求人工确认，`--force` 跳过确认；`--dry-run` 仅预览，不执行删除。删除模式的 CSV 只要求 `subscription_id,subscription_name`，可省略 `prefix,location`。

```bash
python3 scripts/deploy-single-model.py \
  --input ./generated/subscriptions-test1.csv \
  --resource-group rg-foundry \
  --account-name fdry-demo-sub1 \
  --model-info "gpt-6-luna" \
  --delete
```
