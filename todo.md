# TODO

请以微软解决方案架构师的角度编写一个解决方案文档，使用分层、多供应渠道的模型 API 供应方式，满足中国客户稳定使用 Claude/GPT 等海外闭源模型的业务连续性需求。

## 已确认范围

1. 文档采用微软解决方案架构师正式口径，使用合规、韧性、企业采购、可观测、业务连续性等表述，不使用不恰当的风险规避类表述。
2. 方案中的 TPM 数字按客户已确认规划事实写入：每个订阅下 Claude Opus 2M TPM、Sonnet 4M TPM、Haiku 4M TPM；GPT 10M TPM。
3. 客户具备 EA/MCA 下通过 API/ARM/CLI 自动创建 Azure subscription 的计费与权限条件。
4. Azure CLI/Linux 脚本作为参考实现交付，需包含前置检查、占位参数、关键自动化命令和人工确认点，但不承诺在所有租户中零修改直接运行。
5. GitHub Copilot 作为员工 IDE/CLI 中的人机交互式开发工具兜底渠道，不作为 LiteLLM 后端或服务端无人值守 API 池使用。
6. LiteLLM 推荐架构面向 Azure AKS/容器化高可用部署，配套 Redis、PostgreSQL、Key Vault、Azure Monitor / Sentinel 等企业能力。
7. LiteLLM 日志需要支持完整请求/响应记录，用于审计、质量分析和容量优化；同时必须提供加密、RBAC、留存、脱敏、审批和最小权限建议。
8. MCP 推荐以员工本地 VS Code / GitHub Copilot MCP 为主，使用每位员工自己的 OAuth/PAT/token，避免集中共享高权限凭据。
9. MCP 来源标准为官方优先、社区谨慎：GitHub 与 Vercel 使用官方 MCP；Hugging Face 与 Gmail 可提供社区方案和自建 MCP wrapper 建议，并明确安全审查要求。
10. 交付物包括：主 Markdown 方案文档、单独 Azure CLI 脚本、单独 LiteLLM 示例配置、单独 MCP 示例配置。

## 方案要求

1. 首先，微软在 Microsoft Foundry / Azure AI Foundry 产品体系中提供最新 Claude、GPT 模型 API。客户先创建新的 Azure subscription，然后创建 Foundry 资源/项目，再在 Foundry 中创建 Claude 和 GPT 模型端点。该路径作为第一供应渠道，按已确认配额，每个订阅可提供 Claude Opus 2M TPM、Sonnet 4M TPM、Haiku 4M TPM，GPT 10M TPM。
2. 为保证模型端点流量足以支撑约 1000 名客户员工，客户创建 10 个新订阅，每个订阅下创建 Foundry 资源/项目和模型端点；随后将所有端点配置到 LiteLLM 中进行流量负载均衡、主动限流、重试、熔断、降级和可观测管理。多订阅、多端点构成 Claude 的第一备用能力，并通过 LiteLLM 记录流量日志，支撑未来审计、质量分析和容量优化。需提供一个基于 Azure CLI 的 Linux 参考脚本，实现订阅创建、Foundry 资源/项目创建、Claude Opus/Sonnet/Haiku 以及 GPT 5.4/5.5 模型端点创建的自动化骨架。
3. 客户当前主力模型是 Claude 系列，但需要考虑跨境闭源模型供应的不确定性、模型提供方区域政策变化、模型可用性和业务连续性。同时 GPT 模型能力持续演进，部分员工更愿意使用 GPT。因此建议客户将 GPT 作为 Claude 用户的第二供应渠道和用户可选模型。由于 LiteLLM 同时完成 Claude 池化和 GPT 池化，客户员工可在统一入口下选择或切换模型。
4. 为增强 Claude 模型 API 的供应韧性，通过 Partner 为客户提供 Google Vertex AI / Gemini Enterprise Agent Platform 中的 Claude API，作为第三供应渠道。
5. GitHub Copilot 产品可在 IDE/CLI 人机交互开发场景中提供 Claude 和 GPT 模型能力。当 API 型供应渠道受区域、合规、模型可用性或采购链路影响时，客户员工仍可选择 GitHub Copilot 作为第四备用工作方式，确保开发生产力连续性。

## LiteLLM 最佳实践要求

解决方案除了解释微软供应链保障，还需要提供 LiteLLM 层面的最佳实践。LiteLLM 的流量分配策略、主动限流、优化重试、冷却、熔断、日志、审计、预算控制和密钥治理等前置动作，可以降低 Foundry / Vertex 以及底层模型提供方将突发流量判断为异常使用的风险，也能提高整体可用性和可运维性。

第二部分内容为 LiteLLM 最佳实践，需要调研并总结最新 LiteLLM 使用技巧、经验和推荐配置，以指导客户进行合理部署。

## MCP / Skill 推荐要求

解决方案第三部分提供推荐的 Skill / MCP 服务。客户明确提出需要访问 Vercel、Hugging Face、GitHub、Gmail 四个外部服务。需要调研这四个服务的 MCP 现状，并将推荐结果放在解决方案第三部分：

1. GitHub：优先推荐 GitHub 官方 MCP Server。
2. Vercel：优先推荐 Vercel 官方 MCP Server。
3. Hugging Face：如无同等级官方 MCP，推荐经过审查的社区 MCP 或自建 wrapper，并说明 HF_TOKEN、权限范围和供应链审查要求。
4. Gmail：如无同等级官方 MCP，推荐经过审查的社区 MCP 或自建 Google Workspace/Gmail API wrapper，并说明 OAuth、最小权限、人机确认和邮件数据保护要求。

## 输出文件

1. `llm-api-pool-solution.md`：主解决方案文档，Markdown 格式，中文。
2. `scripts/create-foundry-pool.sh`：Azure CLI/Linux 参考自动化脚本。
3. `config/litellm-config.example.yaml`：LiteLLM 示例配置。
4. `.vscode/mcp.example.json`：VS Code / GitHub Copilot 本地 MCP 示例配置。

请注意寻找最新素材，并通过多个渠道核实准确性。所有脚本和配置均使用占位符，不写入真实租户 ID、密钥、token 或客户敏感信息。
