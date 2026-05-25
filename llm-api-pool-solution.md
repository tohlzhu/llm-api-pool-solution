# 中国客户 Claude/GPT 模型 API 高可用供应池解决方案

## 1. 执行摘要

本方案为中国客户设计一套面向 Claude/GPT 等海外闭源模型的多渠道 API 供应池。目标是在企业合规、采购可控、日志可审计、容量可扩展的前提下，为约 1000 名员工提供稳定的模型访问能力。

方案采用五层供应与保障模型：Microsoft Foundry / Azure AI Foundry 作为主供应渠道；10 个 Azure subscription 下的多 Foundry、多端点 Claude 池作为第一备用能力；Microsoft Foundry GPT 池作为第二供应渠道和用户可选模型；Partner 提供的 Google Vertex AI / Gemini Enterprise Agent Platform Claude API 作为第三供应渠道；GitHub Copilot 作为员工 IDE/CLI 人机交互式开发工作兜底方式。LiteLLM 作为统一 API 网关，承担流量调度、主动限流、失败重试、冷却、降级、日志审计和成本治理。对高重复、低交互的定时任务，应建立独立账号池和 LiteLLM 模型组，避免与员工交互式工作负载共享同一组 Claude/GPT 端点。

## 2. 设计目标与边界

### 2.1 设计目标

1. 为 Claude 与 GPT 建立统一的企业模型入口。
2. 使用 10 个 Azure subscription 承载多组 Foundry 模型端点，降低单订阅容量压力。
3. 支持约 1000 名员工的并发使用和容量扩展。
4. 通过 LiteLLM 实现跨订阅、跨模型、跨供应渠道的负载均衡与降级。
5. 记录完整请求/响应日志及审计元数据，支撑安全审计、容量分析、质量分析和成本回溯。
6. 为定时任务、批处理、重复 prompt 工作负载建立独立供应池和独立 LiteLLM group，降低对主交互池的容量、风控和可用性影响。
7. 在 VS Code / GitHub Copilot 中提供本地 MCP 能力，使员工可安全访问 GitHub、Vercel、Hugging Face、Gmail 等外部服务，并按客户审计要求留存 Copilot 代理侧请求记录。

### 2.2 非目标

1. 不将 GitHub Copilot 设计为 LiteLLM 后端或服务端无人值守 API 池。
2. 不在脚本或配置中写入真实租户 ID、订阅 ID、token、密钥或客户敏感信息。
3. 不替代客户的法律、合规、数据跨境、安全评审流程。
4. 不通过账号池、代理或路由策略绕过模型提供方、Marketplace、GitHub Copilot 或企业安全策略；所有隔离设计只用于容量治理、可用性保护和审计留存。
5. 不承诺所有模型、区域、Marketplace SKU 在所有 Azure 订阅类型中均可直接购买或部署；实际可用性以客户租户、计费区域、Marketplace 条款和模型提供方策略为准。

## 3. 关键假设与容量模型

1. 客户具备 EA/MCA 下自动创建 Azure subscription 的计费权限和服务主体授权。
2. 客户计划创建 10 个新 subscription，每个 subscription 下部署一组 Foundry 资源/项目与模型端点。
3. Claude 模型在 Microsoft Foundry 中通过 Anthropic partner model / Marketplace 路径供应；GPT 模型通过 Azure OpenAI in Microsoft Foundry / Foundry Models sold directly by Azure 路径供应。
4. 客户接受完整请求/响应日志记录，并将配套实施加密、最小权限、留存、审批、脱敏和访问审计控制。
5. 客户愿意为定时任务额外预留若干 subscription，例如 5 个，作为低成本模型优先、权限独立、日志独立的批处理供应池。

| 模型族 | 单订阅 TPM | 10 订阅汇总 TPM | 主要用途 |
| --- | ---: | ---: | --- |
| Claude Opus | 2,000,000 | 20,000,000 | 高复杂度编码、架构设计、长任务代理 |
| Claude Sonnet | 4,000,000 | 40,000,000 | 主力编码、日常开发、文档与分析 |
| Claude Haiku | 4,000,000 | 40,000,000 | 低延迟、高频轻量任务 |
| GPT 5.4 / 5.5 | 10,000,000 | 100,000,000 | 通用问答、推理、工具调用、多模态和 Claude 备用 |

定时任务池不应从上述 10 个交互式 subscription 中切走容量。建议额外规划 5 个 subscription，优先部署 `gpt-nano`、`gemini-flash`、`claude-haiku` 等低成本模型，并在 LiteLLM 中暴露为 `batch-*` 模型组。最终 subscription 数量、TPM/RPM 和模型 ID 需以客户租户实际配额、区域可用性和供应商条款验证结果为准。

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

### 4.2.1 LiteLLM model_name 冗余隔离（防政策封禁扩散）

#### 风险背景

Anthropic 和 OpenAI 对模型端点实施内容安全策略检测。当某个 Foundry 端点接收到违反模型使用政策的请求时，该端点可能被暂停或封禁。如果 LiteLLM 中所有用户共用同一个 `model_name`（例如 `claude-sonnet`），该名称下的全部 Foundry endpoint 都暴露在同一风险面中——一次政策违规触发的封禁可能影响该组全部端点，导致所有用户失去对该模型的访问能力。

#### 设计原则

将 LiteLLM 层面的 `model_name` 按冗余组拆分，使每个组只映射到总端点池的子集。当某组内的端点因政策违规被封禁时，仅影响该组用户，其他组不受牵连。

#### 具体方案（以 10 订阅 / 5 组为例）

将 10 个 Foundry 订阅的端点按顺序划分为 5 个隔离组，每组包含 2 个端点：

```
订阅分组:
  Group 1: subscription-01, subscription-02  →  model_name: claude-sonnet-1
  Group 2: subscription-03, subscription-04  →  model_name: claude-sonnet-2
  Group 3: subscription-05, subscription-06  →  model_name: claude-sonnet-3
  Group 4: subscription-07, subscription-08  →  model_name: claude-sonnet-4
  Group 5: subscription-09, subscription-10  →  model_name: claude-sonnet-5
```

同理适用于 `claude-opus-{1..5}`、`claude-haiku-{1..5}`、`gpt-frontier-{1..5}` 等所有主交互模型。

#### 用户分配策略

1. 将 1000 名员工按团队、部门或随机分桶分配到 5 个组之一。
2. 每个团队/用户的 virtual key 绑定对应组的 `model_name`（例如 team-A 使用 `claude-sonnet-1`，team-B 使用 `claude-sonnet-2`）。
3. 分配关系通过 LiteLLM 的 `team_settings` 中的 `models` 字段或 key-level `model_access` 控制。
4. 用户无需关心底层分组，应用侧可通过配置或 header 路由到正确的 model_name。

#### 容灾与降级

1. 组内 2 个端点之间按常规 LiteLLM 路由做负载均衡和 failover。
2. 当某组全部端点被封禁时，该组用户通过 `fallbacks` 降级到其他模型（如 `gpt-frontier-{N}`），而不是自动切换到其他 Claude 组——避免"带病"流量扩散到健康组。
3. 管理员在确认问题源头并处置违规用户后，可手动将受影响组的用户临时迁移到其他组。

#### 隔离效果

| 场景 | 无 model_name 隔离 | 有 5 组隔离 |
| --- | --- | --- |
| 某用户违规触发端点封禁 | 所有 10 个端点暴露风险，可能全员受影响 | 仅该用户所在组的 2 个端点受影响，其余 80% 容量正常 |
| 封禁组内跨端点扩散 | 10 个端点链式风险 | 最大受影响范围限制在 2 个端点 |
| 恢复操作 | 需对全部端点逐一排查 | 只需处理受影响组的 2 个端点和对应用户 |

#### 配套要求

1. 审计日志必须记录每个请求对应的 `model_name` 组号和用户标识，便于追溯违规来源。
2. 运维监控需按 model_name 组粒度展示封禁、429、5xx 状态，快速定位受影响范围。
3. 用户分组映射应存储在 LiteLLM 数据库或外部配置中心，支持动态调整。
4. 定时任务池（`batch-*`）不适用此隔离方案，因其使用独立订阅和端点，已天然隔离。

配套配置示例见 [config/litellm-config.example.yaml](config/litellm-config.example.yaml)。

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

### 4.6 横向隔离：定时任务专用账号池

Claude/GPT 服务端通常具备安全扫描、异常使用检测和滥用防护机制。企业内部定时任务如果长时间发送大量高度重复 prompt，容易在行为模式上与低质量自动化、异常抓取或违规业务流量相似。该风险不应通过规避供应商安全策略解决，而应通过业务隔离、低成本模型优先、日志审计和用户宣导降低对主交互池的影响。

建议建立独立的定时任务账号池：

1. 额外创建若干 subscription，例如 5 个，专门承载定时任务、批处理、报表生成、周期性代码扫描等非交互式工作负载。
2. 在这些 subscription 中部署 Claude Haiku、GPT nano、Gemini Flash 或同级别轻量模型；只有确有质量要求的任务才升级到 Sonnet、Opus 或 frontier GPT。
3. 在 LiteLLM 中将定时任务池隔离为 `batch-claude-haiku`、`batch-gpt-nano`、`batch-gemini-flash` 等模型组，使用独立 virtual key、team budget、TPM/RPM、fallback 和日志策略。
4. 员工和内部系统发起定时任务时，必须显式选择 `batch-*` 模型组；默认交互模型组不接受批处理 token 或长期无人值守任务。
5. 对重复 prompt 做模板版本号、业务系统 ID、任务 ID 和审批人记录，便于解释流量来源、定位异常和向供应商支持团队提交合规说明。
6. 对命中安全策略、429、5xx 或异常冷却的任务设置自动暂停和人工复核，不允许无限重试或多池轮转放大异常请求。

## 5. 目标架构

```text
Developer Apps / Internal Tools / Agents
                 |
                 v
        LiteLLM API Gateway on AKS
        - Auth / virtual keys / teams
        - model_name isolation (5 groups per model)
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
  |                                  |
  v                                  v
model_name isolation:            model_name isolation:
  claude-sonnet-1: sub-01,02       gpt-frontier-1: sub-01,02
  claude-sonnet-2: sub-03,04       gpt-frontier-2: sub-03,04
  claude-sonnet-3: sub-05,06       gpt-frontier-3: sub-05,06
  claude-sonnet-4: sub-07,08       gpt-frontier-4: sub-07,08
  claude-sonnet-5: sub-09,10       gpt-frontier-5: sub-09,10

Scheduled / batch workload pool:
Internal Jobs --> LiteLLM batch-* groups --> Dedicated Foundry / Vertex lightweight endpoints
                                         5 extra subscriptions, isolated keys and logs

Developer fallback workflow:
Employees --> VS Code / GitHub Copilot / MCP --> GitHub, Vercel, HF, Gmail tools
Employees --> Corporate proxy / mitmproxy-copilot --> Elasticsearch / SIEM audit store
```

运维平面建议包括 AKS、Azure Cache for Redis、Azure Database for PostgreSQL、Azure Key Vault、Azure Monitor / Application Insights / Log Analytics / Sentinel，以及用于出口治理的 Private Link、NAT Gateway 或 Firewall。

## 6. LiteLLM 最佳实践

配套配置见 [config/litellm-config.example.yaml](config/litellm-config.example.yaml)。

### 6.1 模型分组与命名

建议以用户视角定义稳定模型别名，底层部署细节对应用透明。为防止政策封禁扩散，每个主交互模型应拆分为 N 个隔离组（推荐 5 组），每组映射到不同的 Foundry 端点子集（详见 4.2.1 节）：

| LiteLLM 模型名 | 底层供应 | 说明 |
| --- | --- | --- |
| `claude-opus-{1..5}` | 每组 2 个 Foundry Claude Opus 端点 | 高复杂度任务，5 组隔离 |
| `claude-sonnet-{1..5}` | 每组 2 个 Foundry Claude Sonnet 端点 | 默认 Claude 主力模型，5 组隔离 |
| `claude-haiku-{1..5}` | 每组 2 个 Foundry Claude Haiku 端点 | 低延迟、高频轻量任务，5 组隔离 |
| `gpt-frontier-{1..5}` | 每组 2 个 Foundry GPT 5.5 / 5.4 端点 | GPT 主力模型，5 组隔离 |
| `gpt-fast-{1..5}` | 每组 2 个 Foundry GPT mini/nano 端点 | 快速低成本任务，5 组隔离 |
| `vertex-claude-sonnet` | Vertex Claude via Partner | Claude 跨云备用（不分组） |
| `batch-claude-haiku` | 定时任务专用 Foundry Claude Haiku 池 | 周期性任务首选 Claude 模型组（独立池已隔离） |
| `batch-gpt-nano` | 定时任务专用 Foundry GPT nano 池 | 低成本、高频重复 prompt |
| `batch-gemini-flash` | 定时任务专用 Vertex Gemini Flash 池 | 跨云轻量批处理备用 |

用户分配到某一组号后，应用层使用对应的 `model_name`（如 `claude-sonnet-3`）发起请求。LiteLLM 的 team/key 配置限定每个用户只能访问其所属组的模型名。

### 6.2 路由、限流与降级

1. 使用 `routing_strategy: simple-shuffle`，并为每个 deployment 设置 `tpm`、`rpm`、`max_parallel_requests`。
2. 将单端点 `tpm` 设置为客户已确认配额的 80% 到 90%，预留平台波动和突发空间。
3. 启用 `enable_weighted_failover: true`，先在同模型组内切换健康端点，再进入跨模型 fallback。
4. 推荐 `num_retries: 2` 或 `3`，并配合 `retry_after`、`allowed_fails`、`cooldown_time`。
5. 对认证错误、权限错误、配额配置错误设置低重试或不重试，避免无效请求放大。
6. 单独配置 `context_window_fallbacks` 和 `content_policy_fallbacks`，不要把所有错误都当作同一种故障。
7. 定时任务必须使用 `batch-*` 模型组和独立 virtual key；生产网关应通过 key 权限、team model allowlist 或应用侧校验，阻止批处理任务调用交互式模型组。
8. 各隔离组的 `fallbacks` 应降级到跨模型（如 `claude-sonnet-N` → `gpt-frontier-N`），而不是降级到同模型的其他组号——避免违规流量扩散到健康组。`content_policy_fallbacks` 同理。

### 6.3 日志与审计

客户要求记录完整请求/响应日志。建议采用分层控制：

1. 默认记录元数据：用户、团队、应用、模型名、部署 ID、端点、token、费用、状态码、延迟、`x-litellm-call-id`。
2. 完整请求/响应日志进入加密存储，开启严格 RBAC、审批访问、留存周期和访问审计。
3. 对敏感部门或敏感数据场景设置独立 virtual key 与独立日志策略。
4. 在生产中启用脱敏与数据分类，至少对 token、密钥、身份证件、邮箱、手机号、客户机密标识做自动识别。
5. 将 LiteLLM 日志接入 Azure Sentinel、OpenTelemetry 或 Langfuse；如使用第三方观测平台，需要单独做数据出境和供应商风险评估。

### 6.4 日志冷热分层与归档

LiteLLM 的 PostgreSQL 数据库适合作为在线控制面和近期审计查询库，但完整请求/响应、spend logs、错误日志在 1000 人规模和定时任务场景下会快速增长。若长期把大体量日志留在同一个 PostgreSQL 主库中，会影响写入延迟、索引膨胀、备份窗口、vacuum 效率和管理 API 查询性能。

建议采用热数据 PostgreSQL、冷数据 ClickHouse 或 Elasticsearch 的分层方案：

1. PostgreSQL 仅保留近 30 天在线日志和控制面数据，用于 LiteLLM 管理、近期问题定位和按 `x-litellm-call-id` 追踪。
2. 每晚低峰期运行 DMS、CDC 或批量 ETL 任务，将 30 天以上日志转移到 ClickHouse 或 Elasticsearch；迁移完成、校验行数和哈希摘要后，再从 PostgreSQL 分区中归档或删除。
3. ClickHouse 适合大规模成本、token、延迟、模型组、团队维度聚合分析；Elasticsearch 适合按请求 ID、用户、错误文本、prompt 片段进行检索和审计调查。
4. 归档任务必须记录水位线、迁移批次、源表范围、目标索引/表名、校验结果和执行人，失败时不删除源数据。
5. 对完整 prompt/response 冷数据继续执行加密、RBAC、留存、脱敏、访问审批和审计，不因移出 PostgreSQL 而降低合规控制。

### 6.5 成本与容量治理

1. 使用 virtual keys 按团队、应用、部门分配模型权限和预算。
2. 对高成本模型设置审批或白名单，例如 Claude Opus、GPT 5.5。
3. 对 `gpt-fast`、`claude-haiku` 设置默认轻量任务入口。
4. 对 `batch-*` 模型组设置更低默认预算、独立成本中心和任务级标签，避免定时任务挤占交互式研发预算。
5. 将 `spend logs` 与成本中心、项目 ID、应用 ID 关联，支持内部 showback/chargeback。
6. 建立容量日报：TPM 峰值、RPM 峰值、429 次数、fallback 次数、端点冷却次数、平均延迟、用户活跃数、定时任务调用量和批处理失败率。

## 7. Azure 自动化建议

本仓库提供账号池批量创建工具，覆盖从订阅创建到模型端点就绪的全流程：

- **[scripts/create-foundry-pool.sh](scripts/create-foundry-pool.sh)**：多订阅 Foundry 池一键创建脚本，支持通过命令行参数指定批次命名前缀和创建套数。
- **[scripts/test-endpoints.sh](scripts/test-endpoints.sh)**：端点连通性验证脚本，自动遍历创建结果清单并逐一测试模型可访问性。

### 7.1 create-foundry-pool.sh 功能

脚本为每一套资源执行完整创建流程：

1. 通过 EA/MCA billing scope 调用 Subscription Alias API 创建新订阅。
2. 将新订阅移入指定管理组（可选）。
3. 在新订阅中注册必要 resource provider。
4. 创建资源组、Key Vault 和 AI Foundry（Cognitive Services AIServices）资源。
5. 在 Foundry 资源上部署 Claude（Opus 4.7、Sonnet 4.6、Haiku 4.5）和 GPT 模型端点。
6. 输出 CSV 清单，包含每个端点的订阅 ID、资源组、Foundry 名称、endpoint URL 和 Key Vault 名。

通过 `--prefix` 参数区分不同批次资源的命名，通过 `--count` 参数控制创建的订阅套数。

### 7.2 命令行用法

```bash
# 列出所有 billing account
az billing account list --query "[].{name:name, type:agreementType}" -o table

# EA 示例
export BILLING_SCOPE="/providers/Microsoft.Billing/billingAccounts/1234567/enrollmentAccounts/7654321"

# MCA 示例
export BILLING_SCOPE="/providers/Microsoft.Billing/billingAccounts/e879cf0f-xxxx:yyyy-zzzz/billingProfiles/AW4F-xxxx-BG7-TGB/invoiceSections/SH3V-xxxx-PJA-TGB"

# 创建 3 套交互式订阅 + 1 套批处理订阅，前缀为 "teamA"
scripts/create-foundry-pool.sh \
  --prefix teamA \
  --count 3 \
  --batch-count 1 \
  --location eastus2 \
  --billing-scope "/providers/Microsoft.Billing/billingAccounts/.../invoiceSections/..."

# 仅创建 Claude 端点（不含 GPT），5 套，前缀 "claude-pool"
scripts/create-foundry-pool.sh \
  --prefix claude-pool \
  --count 5 \
  --no-gpt \
  --no-batch \
  --billing-scope "$BILLING_SCOPE"

# Dry run 模式：打印所有操作但不执行
scripts/create-foundry-pool.sh --prefix test --count 2 --dry-run -s "$BILLING_SCOPE"
```

主要参数：

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `-p, --prefix` | 资源命名前缀，用于区分批次 | `llmpool` |
| `-n, --count` | 交互式订阅套数 | `10` |
| `-b, --batch-count` | 批处理订阅套数 | `5` |
| `-l, --location` | Azure 区域 | `eastus2` |
| `-s, --billing-scope` | EA/MCA 计费范围（必需） | — |
| `-m, --mgmt-group` | 管理组 ID（可选） | — |
| `--no-gpt` | 跳过 GPT 模型部署 | — |
| `--no-claude` | 跳过 Claude 模型部署 | — |
| `--no-batch` | 跳过批处理池创建 | — |
| `--dry-run` | 仅打印操作，不实际执行 | — |

### 7.3 端点连通性测试

创建完成后使用 `test-endpoints.sh` 验证端点可用性：

```bash
# 使用默认 claude-sonnet-4-6 模型测试所有端点
scripts/test-endpoints.sh ./generated/foundry-endpoints.csv

# 指定测试 claude-haiku-4-5
MODEL=claude-haiku-4-5 scripts/test-endpoints.sh

# 显示完整响应
VERBOSE=true scripts/test-endpoints.sh
```

### 7.4 注意事项

需要注意：Foundry 新旧资源模型、Azure CLI 扩展、Marketplace 模型购买 API 和模型 deployment API 会随平台演进而变化。正式投产前，应在客户测试租户中完成以下验证：

1. 使用 `--dry-run` 模式确认脚本将执行的操作。
2. 在测试订阅中验证 Anthropic Claude 模型的 Marketplace 条款接受、区域可用性和部署 API 兼容性。
3. 确认 billing scope 格式、服务主体权限和订阅配额限制。
4. 部署完成后使用 `test-endpoints.sh` 验证所有端点的连通性和模型可访问性。

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

## 9. GitHub Copilot 请求留存方案

客户如要求留存 GitHub Copilot 请求用于审计和后续数据分析，可在员工 IDE 到 GitHub Copilot 服务之间部署企业代理。开源项目 [nikawang/mitmproxy-copilot](https://github.com/nikawang/mitmproxy-copilot) 提供了一个参考实现：基于 mitmproxy 拦截 HTTP/HTTPS 流量，通过 Python 脚本 `proxy-es.py` 将 Copilot 上下文、生成片段、开发者活动、代码生成和接受数据写入 Elasticsearch，并可通过 Kibana 做检索和可视化。mitmproxy 官方文档也说明其支持 HTTP/HTTPS/WebSocket 拦截、TLS 证书动态生成、保存完整 HTTP conversations、以及用 Python 脚本处理流量。

该方案的定位是审计代理，不改变 Copilot 请求内容，不将 Copilot 接入 LiteLLM，也不替代 GitHub Enterprise、Copilot Business/Enterprise 自带的组织级管理与审计能力。正式使用前必须完成法律告知、员工授权、数据分级、跨境与供应商条款评审，并确认代理不会违反 GitHub Copilot、GitHub Enterprise 或客户内部合规要求。

### 9.1 工作原理

1. 员工 VS Code / JetBrains / CLI 将 HTTP(S) 代理指向企业 mitmproxy-copilot 服务。
2. 客户端安装企业签发或代理生成的 mitmproxy 根证书，使 IDE 能通过代理建立 TLS 连接。
3. mitmproxy 只对允许的 GitHub Copilot 相关域名做审计采集，其他域名应 passthrough 或拒绝，减少非目标数据采集。
4. `proxy-es.py` 解析 Copilot 请求和响应，将用户标识、时间、模型/接口、上下文片段、生成片段、接受数据、错误和延迟写入 Elasticsearch。
5. Elasticsearch / Kibana / SIEM 用于按用户、团队、仓库、时间范围、请求 ID、风险关键字和接受率做审计、质量分析与容量分析。

### 9.2 参考部署步骤

1. 从 [nikawang/mitmproxy-copilot](https://github.com/nikawang/mitmproxy-copilot) 拉取代码，在客户受控网络中进行源码、依赖、镜像和许可证审查；该项目 README 显示暂无正式 release，生产应固定 commit SHA 并构建客户自有镜像。
2. 准备 Elasticsearch 与 Kibana，或替换 `proxy-es.py` 将数据写入客户指定的日志平台、对象存储或 SIEM。
3. 按项目 README 使用 Dockerfile 构建镜像，例如 `docker build . -t mitmproxy-copilot:v1`；运行时挂载客户审查后的 `proxy-es.py` 与认证文件。认证文件应由 Key Vault、Kubernetes Secret 或企业密码库下发，不写入 Git。
4. 在代理前放置负载均衡和健康检查；对多节点部署，统一证书、认证、日志 schema 和用户标识映射。
5. 在员工终端安装代理根证书。Windows 可按 mitmproxy 文档和项目 README 示例使用 `certutil -addstore root mitmproxy-ca-cert.cer`，企业环境应优先通过 MDM、GPO 或终端管理系统下发。
6. 在 IDE 中配置 HTTP 代理，格式为 `http://<user>:<password>@<proxy-host>:<proxy-port>`；如启用严格 TLS 校验，确保证书链被终端信任。
7. 分批试点，验证 Copilot 登录、补全、Chat、模型选择、MCP 调用和网络降级行为；按请求 ID 抽查代理日志、GitHub 侧审计日志和终端日志是否可关联。

### 9.3 风险与控制

1. 不修改 Copilot 请求字段、头部、body 或响应内容；项目 README 明确提醒修改 HTTP 字段可能被 GitHub 检测并导致账号风险。
2. 代理采集内容可能包含源代码、prompt、生成代码、个人信息和客户机密，必须默认加密存储、限制访问、设置留存周期和审批流程。
3. 代理自身是敏感基础设施，应启用访问日志、管理员操作审计、漏洞扫描、镜像签名、最小权限和高可用部署。
4. 对高敏感团队可以只采集元数据或脱敏摘要；完整请求/响应采集需单独审批。
5. 定期核验 GitHub Copilot 客户端域名、协议和产品行为变化，避免因客户端升级造成漏采、阻断或误采。

## 10. 安全、合规与治理

1. 应用访问 LiteLLM 使用 virtual key，不直接访问底层模型端点。
2. LiteLLM 到 Foundry 使用 Key Vault 管理密钥，定期轮换。
3. 管理员、审计员、开发者、应用服务主体分离权限。
4. MCP 使用员工个人身份，避免共享 PAT。
5. 完整请求/响应日志默认加密存储，按数据分类设置留存周期。
6. Foundry 与 Azure OpenAI 作为主供应链，优先纳入微软企业支持体系。
7. 社区 MCP 需纳入 OSS 依赖治理，建议固定版本和镜像摘要。
8. GitHub Copilot 请求留存必须完成员工告知、授权、最小化采集、留存审批和访问审计；代理账号、证书和 Elasticsearch 凭据不得出现在仓库中。
9. 定时任务账号池不得用于规避模型安全策略；异常重复 prompt、风控命中和供应商告警必须进入安全事件流程。

## 11. 实施路线图

| 阶段 | 周期 | 关键任务 | 退出标准 |
| --- | --- | --- | --- |
| 0. 设计确认 | 1 周 | 确认订阅、区域、模型 SKU、配额、日志策略、合规要求 | 架构和安全评审通过 |
| 1. PoC | 1-2 周 | 创建 1-2 个 subscription，部署 Foundry Claude/GPT，接入 LiteLLM | 完成端到端调用、日志和 fallback 测试 |
| 2. 扩容 | 2-3 周 | 扩展到 10 个交互 subscription 和定时任务专用 subscription，接入 Redis/Postgres/Key Vault/Monitor | 达到规划 TPM，压测通过，`batch-*` 隔离策略生效 |
| 3. 生产试运行 | 2 周 | 接入试点团队，启用 virtual key、预算、审计，试点 Copilot 代理留存 | 100-200 人稳定使用，Copilot 审计链路可查询 |
| 4. 全员上线 | 持续 | 扩展到 1000 人，建立容量日报和异常演练 | SLA、成本和审计指标达标 |

## 12. 验证与演练

1. 容量压测：逐步提升到单模型组 60%、80%、100% 规划容量。
2. 故障演练：模拟单 subscription 429、单区域超时、单模型不可用、Vertex fallback。
3. 日志验证：按 `x-litellm-call-id` 贯穿应用日志、LiteLLM 日志和 Sentinel 事件。
4. 权限验证：普通员工无法访问底层 Foundry key，审计员只读访问日志。
5. MCP 验证：GitHub/Vercel 写操作必须触发人工确认，Gmail 发送邮件默认禁止或需二次确认。
6. 定时任务隔离验证：批处理 virtual key 只能访问 `batch-*` 模型组，交互式 key 默认不能访问批处理池；重复 prompt 触发暂停和人工复核流程。
9. model_name 隔离验证：模拟某组端点被封禁，确认仅该组用户受影响，其他组可正常使用；确认 fallback 不跨组、只跨模型。
7. 日志归档验证：夜间 DMS/ETL 任务能迁移 30 天以上日志，完成行数校验、查询回放和源端清理，且失败时不删除源数据。
8. Copilot 留存验证：抽样确认 IDE 请求经代理写入 Elasticsearch/SIEM，证书、代理认证、用户映射和脱敏策略符合安全评审要求。

## 13. 资料核验说明

交付前建议再次核验以下官方来源，因为模型、区域、quota tier 和 MCP 能力更新较快：

1. Microsoft Learn：Microsoft Foundry、Foundry Models sold directly by Azure、Azure OpenAI GPT 5.4/5.5、Foundry Models from partners and community、Anthropic partner model、Foundry project 创建文档。
2. Microsoft Learn：EA/MCA programmatic subscription creation、Subscription Alias API、Azure billing scope、Marketplace/SaaS 权限文档。
3. LiteLLM Docs [litellm doc](https://docs.litellm.ai/docs/)：routing、proxy config、fallbacks/reliability、logging、OpenTelemetry、Azure Sentinel、Redis router state、virtual keys。
4. Google Cloud Docs：Vertex AI / Gemini Enterprise Agent Platform Claude partner models、Claude model cards、request/response logging。
5. GitHub Docs 与 `github/github-mcp-server`：GitHub official MCP server、remote MCP、local Docker MCP、toolsets、read-only、lockdown mode。
6. Vercel Docs：Vercel official MCP `https://mcp.vercel.com`、OAuth、supported clients、安全最佳实践。
7. Model Context Protocol 官方文档与 MCP Registry：MCP 架构、reference servers、社区服务器发现与安全评估原则。
8. mitmproxy 官方文档与 [nikawang/mitmproxy-copilot](https://github.com/nikawang/mitmproxy-copilot)：TLS 证书安装、代理模式、脚本扩展、Elasticsearch 写入方式、支持的 Copilot 端点和项目维护状态。
