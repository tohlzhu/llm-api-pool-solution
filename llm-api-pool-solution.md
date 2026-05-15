# 中国客户 Claude/GPT 模型 API 高可用供应池解决方案

## 1. 执行摘要

本方案为中国客户设计一套面向 Claude/GPT 等海外闭源模型的多渠道 API 供应池。目标是在企业合规、采购可控、日志可审计、容量可扩展的前提下，为约 1000 名员工提供稳定的模型访问能力。

方案采用五层供应与保障模型：Microsoft Foundry / Azure AI Foundry 作为主供应渠道；10 个 Azure subscription 下的多 Foundry、多端点 Claude 池作为第一备用能力；Microsoft Foundry GPT 池作为第二供应渠道和用户可选模型；Partner 提供的 Google Vertex AI / Gemini Enterprise Agent Platform Claude API 作为第三供应渠道；GitHub Copilot 作为员工 IDE/CLI 人机交互式开发工作兜底方式。LiteLLM 作为统一 API 网关，承担流量调度、主动限流、失败重试、冷却、降级、日志审计和成本治理。

## 2. 设计目标与边界

### 2.1 设计目标

1. 为 Claude 与 GPT 建立统一的企业模型入口。
2. 使用 10 个 Azure subscription 承载多组 Foundry 模型端点，降低单订阅容量压力。
3. 支持约 1000 名员工的并发使用和容量扩展。
4. 通过 LiteLLM 实现跨订阅、跨模型、跨供应渠道的负载均衡与降级。
5. 记录完整请求/响应日志及审计元数据，支撑安全审计、容量分析、质量分析和成本回溯。
6. 在 VS Code / GitHub Copilot 中提供本地 MCP 能力，使员工可安全访问 GitHub、Vercel、Hugging Face、Gmail 等外部服务。

### 2.2 非目标

1. 不将 GitHub Copilot 设计为 LiteLLM 后端或服务端无人值守 API 池。
2. 不在脚本或配置中写入真实租户 ID、订阅 ID、token、密钥或客户敏感信息。
3. 不替代客户的法律、合规、数据跨境、安全评审流程。
4. 不承诺所有模型、区域、Marketplace SKU 在所有 Azure 订阅类型中均可直接购买或部署；实际可用性以客户租户、计费区域、Marketplace 条款和模型提供方策略为准。

## 3. 关键假设与容量模型

1. 客户具备 EA/MCA 下自动创建 Azure subscription 的计费权限和服务主体授权。
2. 客户计划创建 10 个新 subscription，每个 subscription 下部署一组 Foundry 资源/项目与模型端点。
3. Claude 模型在 Microsoft Foundry 中通过 Anthropic partner model / Marketplace 路径供应；GPT 模型通过 Azure OpenAI in Microsoft Foundry / Foundry Models sold directly by Azure 路径供应。
4. 客户接受完整请求/响应日志记录，并将配套实施加密、最小权限、留存、审批、脱敏和访问审计控制。

| 模型族 | 单订阅 TPM | 10 订阅汇总 TPM | 主要用途 |
| --- | ---: | ---: | --- |
| Claude Opus | 2,000,000 | 20,000,000 | 高复杂度编码、架构设计、长任务代理 |
| Claude Sonnet | 4,000,000 | 40,000,000 | 主力编码、日常开发、文档与分析 |
| Claude Haiku | 4,000,000 | 40,000,000 | 低延迟、高频轻量任务 |
| GPT 5.4 / 5.5 | 10,000,000 | 100,000,000 | 通用问答、推理、工具调用、多模态和 Claude 备用 |

面向 1000 名员工时，建议将总容量按用户分组、团队预算、业务优先级和模型成本做二次切分。LiteLLM 中的 virtual key、team budget、per-model TPM/RPM、max parallel requests 和审计日志，是把总容量变成可运营服务的关键控制面。

## 4. 分层供应架构

### 4.1 第一层：Microsoft Foundry 主渠道

客户在 Microsoft Foundry / Azure AI Foundry 中创建 Foundry 资源和项目，并部署 Claude 与 GPT 模型端点。Foundry 提供企业级身份、网络、计费、监控和 Azure 治理集成，是本方案首选供应渠道。

关键实施点：

1. 每个 subscription 独立承载 Claude Opus、Sonnet、Haiku 与 GPT 5.4 / 5.5 端点。
2. 每个端点在 LiteLLM 中作为独立 deployment 注册，设置明确的 `tpm`、`rpm`、`max_parallel_requests` 和健康状态。
3. 使用 Azure Key Vault 保存端点密钥，避免在 LiteLLM 配置中直接写入 secret。
4. 对 Foundry 资源、模型端点、Key Vault、AKS、Redis、PostgreSQL、日志存储配置统一标签，便于成本、审计和责任归属。

### 4.2 第二层：多订阅 Claude 池化能力

10 个 subscription 的核心价值不是简单扩大账面配额，而是把容量拆成多个健康单元。LiteLLM 在同一个用户可见模型名下注册多个 Foundry Claude deployment，并根据 TPM/RPM 权重、当前使用量、失败状态和冷却状态进行选择。

推荐策略：

1. 生产默认使用 `simple-shuffle`，并为所有 deployment 设置 `tpm` / `rpm`，让 LiteLLM 根据容量做加权选择。
2. 启用 Redis 作为多 LiteLLM 实例之间的共享状态，避免 AKS 横向扩容后每个 pod 都误以为自己拥有完整配额。
3. 启用 weighted failover，使某个 Azure endpoint 失败时先在同一模型组内切换健康端点，再进入跨模型 fallback。
4. 为 429、5xx、timeout 设置冷却与有限重试，避免短时间内持续打向同一异常端点。

### 4.3 第三层：GPT 池化与用户可选模型

客户当前以 Claude 为主，但 GPT 模型能力持续演进，且部分员工更适应 GPT 工作流。方案建议将 GPT 作为与 Claude 并行的一等模型池，而不是只在故障时被动使用。

在 LiteLLM 中建议设置两类模型别名：

1. `claude-sonnet`、`claude-opus`、`claude-haiku`：默认进入 Claude 池。
2. `gpt-frontier`、`gpt-fast`：默认进入 GPT 池。

同时为 Claude 模型配置 GPT fallback，使 Claude 模型组在全部同模型端点不可用后，可按策略降级至 GPT。对需要模型一致性的业务，要求应用显式声明 fallback 策略。

### 4.4 第四层：Partner Vertex Claude 渠道

通过 Partner 为客户提供 Google Vertex AI / Gemini Enterprise Agent Platform 中的 Claude API，作为 Claude 的跨云供应补充。该渠道不替代 Foundry 主渠道，但在 Foundry Claude 端点受 Marketplace、区域可用性、订阅异常或模型提供方策略影响时，提供独立供应路径。

LiteLLM 中应将 Vertex Claude 放在 Claude 模型组的后序 fallback，避免日常流量优先打到第三方 Partner 渠道，同时确保故障时可用。跨云账单、支持路径、SLA、区域可用性和数据处理条款应单独登记。

### 4.5 第五层：GitHub Copilot 开发工作兜底

GitHub Copilot 可在 VS Code、JetBrains、GitHub CLI、Copilot CLI 等人机交互式开发场景中提供 Claude 和 GPT 模型能力。该能力应定位为员工开发生产力兜底方式：当 API 型渠道因采购、区域、配额或模型可用性出现影响时，员工仍可在 IDE/CLI 中继续完成代码理解、生成、重构和调试任务。

Copilot 不进入 LiteLLM API 池，不作为服务端自动化模型后端使用。

## 5. 目标架构

```text
Developer Apps / Internal Tools / Agents
                 |
                 v
        LiteLLM API Gateway on AKS
        - Auth / virtual keys / teams
        - routing / fallback / cooldown
        - full request-response logging
        - cost and quota governance
                 |
  +--------------+-------------------+-------------------+
  |                                  |                   |
  v                                  v                   v
Azure Foundry Claude Pool      Azure Foundry GPT Pool    Vertex Claude via Partner
10 subscriptions               10 subscriptions          Separate cloud/provider path
Opus/Sonnet/Haiku              GPT 5.4 / GPT 5.5         Claude Opus/Sonnet/Haiku

Developer fallback workflow:
Employees --> VS Code / GitHub Copilot / MCP --> GitHub, Vercel, HF, Gmail tools
```

运维平面建议包括 AKS、Azure Cache for Redis、Azure Database for PostgreSQL、Azure Key Vault、Azure Monitor / Application Insights / Log Analytics / Sentinel，以及用于出口治理的 Private Link、NAT Gateway 或 Firewall。

## 6. LiteLLM 最佳实践

配套配置见 [config/litellm-config.example.yaml](config/litellm-config.example.yaml)。

### 6.1 模型分组与命名

建议以用户视角定义稳定模型别名，底层部署细节对应用透明：

| LiteLLM 模型名 | 底层供应 | 说明 |
| --- | --- | --- |
| `claude-opus` | Foundry Claude Opus 多订阅池 | 高复杂度任务 |
| `claude-sonnet` | Foundry Claude Sonnet 多订阅池 | 默认 Claude 主力模型 |
| `claude-haiku` | Foundry Claude Haiku 多订阅池 | 低延迟、高频轻量任务 |
| `gpt-frontier` | Foundry GPT 5.5 / GPT 5.4 多订阅池 | GPT 主力模型 |
| `gpt-fast` | Foundry GPT 5.4 mini/nano 或后续轻量模型 | 快速低成本任务 |
| `vertex-claude-sonnet` | Vertex Claude via Partner | Claude 跨云备用 |

### 6.2 路由、限流与降级

1. 使用 `routing_strategy: simple-shuffle`，并为每个 deployment 设置 `tpm`、`rpm`、`max_parallel_requests`。
2. 将单端点 `tpm` 设置为客户已确认配额的 80% 到 90%，预留平台波动和突发空间。
3. 启用 `enable_weighted_failover: true`，先在同模型组内切换健康端点，再进入跨模型 fallback。
4. 推荐 `num_retries: 2` 或 `3`，并配合 `retry_after`、`allowed_fails`、`cooldown_time`。
5. 对认证错误、权限错误、配额配置错误设置低重试或不重试，避免无效请求放大。
6. 单独配置 `context_window_fallbacks` 和 `content_policy_fallbacks`，不要把所有错误都当作同一种故障。

### 6.3 日志与审计

客户要求记录完整请求/响应日志。建议采用分层控制：

1. 默认记录元数据：用户、团队、应用、模型名、部署 ID、端点、token、费用、状态码、延迟、`x-litellm-call-id`。
2. 完整请求/响应日志进入加密存储，开启严格 RBAC、审批访问、留存周期和访问审计。
3. 对敏感部门或敏感数据场景设置独立 virtual key 与独立日志策略。
4. 在生产中启用脱敏与数据分类，至少对 token、密钥、身份证件、邮箱、手机号、客户机密标识做自动识别。
5. 将 LiteLLM 日志接入 Azure Sentinel、OpenTelemetry 或 Langfuse；如使用第三方观测平台，需要单独做数据出境和供应商风险评估。

### 6.4 成本与容量治理

1. 使用 virtual keys 按团队、应用、部门分配模型权限和预算。
2. 对高成本模型设置审批或白名单，例如 Claude Opus、GPT 5.5。
3. 对 `gpt-fast`、`claude-haiku` 设置默认轻量任务入口。
4. 将 `spend logs` 与成本中心、项目 ID、应用 ID 关联，支持内部 showback/chargeback。
5. 建立容量日报：TPM 峰值、RPM 峰值、429 次数、fallback 次数、端点冷却次数、平均延迟、用户活跃数。

## 7. Azure 自动化建议

本仓库提供 [scripts/create-foundry-pool.sh](scripts/create-foundry-pool.sh) 作为参考实现。脚本遵循以下原则：

1. 使用 EA/MCA billing scope 创建 subscription alias。
2. 对每个 subscription 注册必要 provider。
3. 创建资源组、Foundry/Cognitive Services 资源、Key Vault 和模型部署占位。
4. 对 Anthropic Claude 相关 Marketplace 条款、区域支持、订阅类型支持设置人工确认和占位。
5. 输出 LiteLLM 所需 endpoint、deployment name、Key Vault secret name、region、model group 等配置片段。

需要注意：Foundry 新旧资源模型、Azure CLI 扩展、Marketplace 模型购买 API 和模型 deployment API 会随平台演进而变化。正式投产前，应在客户测试租户中完成脚本 dry run、权限验证、模型 SKU 验证和配额验证。

## 8. MCP / Skill 推荐

配套 VS Code 示例见 [.vscode/mcp.example.json](.vscode/mcp.example.json)。

### 8.1 推荐原则

1. 官方 MCP 优先。
2. 员工本地授权优先，不共享企业级高权限 token。
3. 写操作必须保留人工确认。
4. 社区 MCP 必须经过源码审查、依赖扫描、容器隔离和权限最小化。
5. 对邮件、代码仓库、部署系统等高敏感服务，必须记录工具调用日志。

### 8.2 服务推荐

| 服务 | 推荐 MCP | 状态 | 认证方式 | 建议 |
| --- | --- | --- | --- | --- |
| GitHub | `github/github-mcp-server` 或 GitHub remote MCP `https://api.githubcopilot.com/mcp/` | 官方 | OAuth 或 fine-grained PAT | 优先使用官方 remote MCP；企业可启用 read-only、toolsets、lockdown mode |
| Vercel | Vercel MCP `https://mcp.vercel.com` | 官方 Beta | OAuth | 用于项目、部署、日志和文档；只连接受信任客户端 |
| Hugging Face | `evalstate/mcp-hfspace`、`shreyaskarnik/huggingface-mcp-server` 或自建 wrapper | 社区/自建 | `HF_TOKEN` | 用于模型/数据集/Spaces 查询；上线前做供应链审查和权限收敛 |
| Gmail | `vladmsv/mcp-server-gmail` 或自建 Google Workspace Gmail API wrapper | 社区/自建 | Google OAuth | 邮件数据敏感，建议先只读、限定 scope、强制人工确认发送邮件 |

## 9. 安全、合规与治理

1. 应用访问 LiteLLM 使用 virtual key，不直接访问底层模型端点。
2. LiteLLM 到 Foundry 使用 Key Vault 管理密钥，定期轮换。
3. 管理员、审计员、开发者、应用服务主体分离权限。
4. MCP 使用员工个人身份，避免共享 PAT。
5. 完整请求/响应日志默认加密存储，按数据分类设置留存周期。
6. Foundry 与 Azure OpenAI 作为主供应链，优先纳入微软企业支持体系。
7. 社区 MCP 需纳入 OSS 依赖治理，建议固定版本和镜像摘要。

## 10. 实施路线图

| 阶段 | 周期 | 关键任务 | 退出标准 |
| --- | --- | --- | --- |
| 0. 设计确认 | 1 周 | 确认订阅、区域、模型 SKU、配额、日志策略、合规要求 | 架构和安全评审通过 |
| 1. PoC | 1-2 周 | 创建 1-2 个 subscription，部署 Foundry Claude/GPT，接入 LiteLLM | 完成端到端调用、日志和 fallback 测试 |
| 2. 扩容 | 2-3 周 | 扩展到 10 个 subscription，接入 Redis/Postgres/Key Vault/Monitor | 达到规划 TPM，压测通过 |
| 3. 生产试运行 | 2 周 | 接入试点团队，启用 virtual key、预算、审计 | 100-200 人稳定使用 |
| 4. 全员上线 | 持续 | 扩展到 1000 人，建立容量日报和异常演练 | SLA、成本和审计指标达标 |

## 11. 验证与演练

1. 容量压测：逐步提升到单模型组 60%、80%、100% 规划容量。
2. 故障演练：模拟单 subscription 429、单区域超时、单模型不可用、Vertex fallback。
3. 日志验证：按 `x-litellm-call-id` 贯穿应用日志、LiteLLM 日志和 Sentinel 事件。
4. 权限验证：普通员工无法访问底层 Foundry key，审计员只读访问日志。
5. MCP 验证：GitHub/Vercel 写操作必须触发人工确认，Gmail 发送邮件默认禁止或需二次确认。

## 12. 资料核验说明

交付前建议再次核验以下官方来源，因为模型、区域、quota tier 和 MCP 能力更新较快：

1. Microsoft Learn：Microsoft Foundry、Foundry Models sold directly by Azure、Azure OpenAI GPT 5.4/5.5、Foundry Models from partners and community、Anthropic partner model、Foundry project 创建文档。
2. Microsoft Learn：EA/MCA programmatic subscription creation、Subscription Alias API、Azure billing scope、Marketplace/SaaS 权限文档。
3. LiteLLM Docs：routing、proxy config、fallbacks/reliability、logging、OpenTelemetry、Azure Sentinel、Redis router state、virtual keys。
4. Google Cloud Docs：Vertex AI / Gemini Enterprise Agent Platform Claude partner models、Claude model cards、request/response logging。
5. GitHub Docs 与 `github/github-mcp-server`：GitHub official MCP server、remote MCP、local Docker MCP、toolsets、read-only、lockdown mode。
6. Vercel Docs：Vercel official MCP `https://mcp.vercel.com`、OAuth、supported clients、安全最佳实践。
7. Model Context Protocol 官方文档与 MCP Registry：MCP 架构、reference servers、社区服务器发现与安全评估原则。
