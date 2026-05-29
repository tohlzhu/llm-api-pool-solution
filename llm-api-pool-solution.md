# 中国客户 Claude/GPT 模型 API 高可用供应池解决方案

## 1. 执行摘要

本方案为中国客户设计一套面向 Claude/GPT 等海外闭源模型的多渠道 API 供应池。目标是在企业合规、采购可控、日志可审计、容量可扩展的前提下，为约 1000 名员工提供稳定的模型访问能力。

方案采用五层供应与保障模型：Microsoft Foundry / Azure AI Foundry 作为主供应渠道；10 个 Azure subscription 下的多 Foundry、多端点 Claude 池作为第一备用能力；Microsoft Foundry GPT 池作为第二供应渠道和用户可选模型；Partner 提供的 Google Vertex AI / Gemini Enterprise Agent Platform Claude API 作为第三供应渠道；GitHub Copilot 作为员工 IDE/CLI 人机交互式开发工作兜底方式。LiteLLM 作为统一 API 网关，承担流量调度、主动限流、失败重试、冷却、降级、日志审计和成本治理。对高重复、低交互的定时任务，建立独立账号池和 LiteLLM 模型组，避免与员工交互式工作负载共享同一组 Claude/GPT 端点。

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

1. 不在脚本或配置中写入真实租户 ID、订阅 ID、token、密钥或客户敏感信息。
2. 不替代客户的法律、合规、数据跨境、安全评审流程。
3. 不通过账号池、代理或路由策略绕过模型提供方、Marketplace、GitHub Copilot 或企业安全策略；所有隔离设计只用于容量治理、可用性保护和审计留存。
4. 不承诺所有模型、区域、Marketplace SKU 在所有 Azure 订阅类型中均可直接购买或部署；实际可用性以客户租户、计费区域、Marketplace 条款和模型提供方策略为准。

## 3. 关键假设与容量模型（举例）

1. 客户具备 EA/MCA 下自动创建 Azure subscription 的计费权限和服务主体授权。
2. 客户计划创建 3 类 Azure 订阅，其中 A 类 10 个（用于 Claude Code 终端），B 类 7 个（5 个用于 codex 终端，2 个用于定时任务），C 类 1 个(用于通用场景)。A/B/C 类的描述如下： 
  - A. Claude 订阅，订阅名约定为 {prefix}-sub{N}，每订阅中 1 个 foundry 实例，foundry 实例中 model_name = "claude-opus-4-7", model_name = "claude-sonnet-4-6", model_name = "claude-haiku-4-5" 的端点各 1 个，区域统一选择为 eastus2；
  - B. GPT 订阅，订阅名约定为 {prefix}-sub{N}，每订阅中 1 个 foundry 实例，foundry 实例中 model_name = "gpt-5.5", model_name = "gpt-5.4", model_name = "gpt-5.4-mini", model_name = "gpt-5.4-nano" 的端点各 1 个，区域统一选择为 eastus2；
  - C. DeepSeek 订阅，订阅名约定为 {prefix}-sub{N}，每订阅中 1 个 foundry 实例，foundry 实例中 model_name = "DeepSeek-V4-Pro", model_name = "DeepSeek-V4-Flash" 的端点各 1 个，区域统一选择为 eastus2；
3. Claude 模型在 Microsoft Foundry 中通过 Anthropic partner model / Marketplace 路径供应；GPT 模型通过 Azure OpenAI in Microsoft Foundry / Foundry Models sold directly by Azure 路径供应。
4. 客户接受完整请求/响应日志记录，并将配套实施加密、最小权限、留存、审批、脱敏和访问审计控制。

| 模型族 | 单订阅 TPM | 订阅汇总 TPM | 主要用途 |
| --- | ---: | ---: | --- |
| Claude Opus | 2,000,000 | 20,000,000 | 高复杂度编码、架构设计、长任务代理 |
| Claude Sonnet | 4,000,000 | 40,000,000 | 主力编码、日常开发、文档与分析 |
| Claude Haiku | 4,000,000 | 40,000,000 | 低延迟、高频轻量任务 |
| GPT 5.5 | 10,000,000 | 70,000,000 | 通用问答、推理、工具调用、多模态和 Claude 备用 |
| GPT 5.4 mini | 10,000,000 | 70,000,000 | 低延迟、高频推理和代码辅助 |
| GPT 5.4 nano | 10,000,000 | 70,000,000 | 低延迟、高频推理 |
| DeepSeek V4 Pro | 10,000,000 | 10,000,000 | 高质量推理、数学、代码和中文任务 |
| DeepSeek V4 Flash | 10,000,000 | 10,000,000 | 低延迟、高频推理和代码辅助 |

在 litellm 层面，（假设有 5 个开发 team）

1. 将 10 个 A 类订阅/端点分配给 5 组 model_name (claude-opus-4-7-grp{1..5}, claude-sonnet-4-6-grp{1..5}, claude-haiku-4-5-grp{1..5})，分别交付给 5 个开发 team 使用，这样 1 个 team 的异常行为只会 block 掉自己所用的 model_name 后的大模型端点，避免事故扩散；
2. 将 5 个 B 类订阅/端点（由于 B 类端点容量较大，达到 10M tpm）分配给 5 组 model_name (gpt-5.5-grp{1..5}, gpt-5.4-grp{1..5}, gpt-5.4-mini-grp{1..5}, gpt-5.4-nano-grp{1..5})，分别交付给 5 个开发 team 使用；
3. 将 2 个 B 类订阅/端点分配给 2 组 model_name (batch-gpt-5.5-grp{1..2}, batch-gpt-5.4-grp{1..2}, batch-gpt-5.4-mini-grp{1..2}, batch-gpt-5.4-nano-grp{1..2})，供开发 team 在定时任务类负载中使用；
4. 将 1 个 C 类订阅/端点分配给 1 组 model_name (DeepSeek-V4-Pro-grp1, DeepSeek-V4-Flash-grp1)，供开发 team 公用；

面向 1000 名员工时，建议将总容量按用户分组、团队预算、业务优先级和模型成本做二次切分。LiteLLM 中的 virtual key、team budget、per-model TPM/RPM、max parallel requests 和审计日志，是把总容量变成可运营服务的关键控制面。

## 4. 分层供应架构

### 4.1 第一层：Microsoft Foundry 主渠道

客户在 Microsoft Foundry / Azure AI Foundry 中创建 Foundry 资源和项目，并部署 Claude 与 GPT 模型端点。Foundry 提供企业级身份、网络、计费、监控和 Azure 治理集成，是本方案首选供应渠道。

关键实施点：

1. 每个 subscription 独立承载 Claude Opus、Sonnet、Haiku 或 GPT 端点。
2. 每个端点在 LiteLLM 中作为独立 deployment 注册，设置明确的 `tpm`、`rpm`、`max_parallel_requests` 和健康状态。
3. 使用 Azure Key Vault 保存端点密钥，避免在 LiteLLM 配置中直接写入 secret。
4. 对 Foundry 资源、模型端点、Key Vault、AKS、Redis、PostgreSQL、日志存储配置统一标签，便于成本、审计和责任归属。

### 4.2 第二层：多订阅 Claude 池化能力

多个 subscription 的核心价值不是简单扩大账面配额，而是把容量拆成多个健康单元。LiteLLM 在同一个用户可见模型名下注册多个 Foundry Claude deployment，并根据 TPM/RPM 权重、当前使用量、失败状态和冷却状态进行选择。

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
  Group 1: llmpool-sub01, llmpool-sub02  →  model_name: claude-sonnet-4-6-grp1
  Group 2: llmpool-sub03, llmpool-sub04  →  model_name: claude-sonnet-4-6-grp2
  Group 3: llmpool-sub05, llmpool-sub06  →  model_name: claude-sonnet-4-6-grp3
  Group 4: llmpool-sub07, llmpool-sub08  →  model_name: claude-sonnet-4-6-grp4
  Group 5: llmpool-sub09, llmpool-sub10  →  model_name: claude-sonnet-4-6-grp5
```

同理适用于所有模型。

#### 用户分配策略

1. 将 1000 名员工按团队、部门或随机分桶分配到 5 个组之一。
2. 每个团队/用户的 virtual key 绑定对应组的 `model_name`（例如 team-A 使用 `claude-sonnet-4-6-grp1`，team-B 使用 `claude-sonnet-4-6-grp2`）。
3. 分配关系通过 LiteLLM 的 `team_settings` 中的 `models` 字段或 key-level `model_access` 控制。
4. 用户无需关心底层分组，应用侧可通过配置或 header 路由到正确的 model_name。

#### 容灾与降级

1. 组内 2 个端点之间按常规 LiteLLM 路由做负载均衡和 failover。
2. 当某组全部端点被封禁时，该组用户通过 `fallbacks` 首先降级到其他供应商的相同模型（如 `vertex-claude-opus-4-7-grp{N}`），次之降级到跨类型的模型（如 `gpt-5.5-grp{N}`），而不是自动切换到其他 Claude 组——避免"带病"流量扩散到健康组。
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

1. `claude-opus-*`、`claude-sonnet-*`、`claude-haiku-*`：默认进入 Claude 池。
2. `gpt-*`：默认进入 GPT 池。

同时为 Claude 模型配置多级 fallback：Foundry Claude 端点不可用时，首先降级至 GCP Vertex AI Claude 端点（同模型类型，保证输出风格和能力一致性），仅当所有 Claude 供应渠道均不可用时，才降级至 GPT。该优先级确保 Claude 工作负载在 fallback 后行为一致、不因模型类型切换导致工作异常。对需要严格模型一致性的业务，要求应用显式声明 fallback 策略或禁用跨模型降级。

### 4.4 第四层：Partner Vertex Claude 渠道

通过 Partner 为客户提供 Google Vertex AI / Gemini Enterprise Agent Platform 中的 Claude API，作为 Claude 的跨云供应补充。该渠道不替代 Foundry 主渠道，但在 Foundry Claude 端点受 Marketplace、区域可用性、订阅异常或模型提供方策略影响时，提供独立供应路径。

LiteLLM 中应将 Vertex Claude 放在 Foundry Claude 的**首选 fallback**位置（优先于 GPT），确保降级后模型类型一致、输出风格和能力不变。日常流量仍优先走 Foundry，只有 Foundry Claude 端点不可用时才切换到 Vertex Claude；所有 Claude 渠道均不可用时，再降级至 GPT。该设计保证 Claude 为主的工作负载在 fallback 后不会因模型切换而出现格式、能力或行为异常。跨云账单、支持路径、SLA、区域可用性和数据处理条款应单独登记。

### 4.5 第五层：GitHub Copilot Vibe Coding 方案

GitHub Copilot 是面向中国区客户的 **Vibe Coding 首选推荐方案**，不仅是模型 API，而是 Harness + 模型 API 的完整 Vibe Coding 解决方案。它将 AI 模型能力、Agent Mode、Coding Agent、代码审查和企业治理集成在一个平台中，是开发者获得 AI 编码能力的最快路径。

Copilot 不进入 LiteLLM API 池（多人共享 1 个账号会导致封号），但可封装为 1 对 1 的账号池作为单个员工场景的模型后端使用。完整方案描述、部署步骤、审计留存、MCP 集成和合规注意事项详见 **[GitHub Copilot 完整方案文档](github-copilot-solution.md)**。

### 4.6 横向隔离：定时任务专用账号池

Claude/GPT 服务端通常具备安全扫描、异常使用检测和滥用防护机制。企业内部定时任务如果长时间发送大量高度重复 prompt，容易在行为模式上与低质量自动化、异常抓取或违规业务流量相似。该风险不应通过规避供应商安全策略解决，而应通过业务隔离、低成本模型优先、日志审计和用户宣导降低对主交互池的影响。

建议建立独立的定时任务账号池：

1. 额外创建若干 subscription，例如 2 个，专门承载定时任务、批处理、报表生成、周期性代码扫描等非交互式工作负载。
2. 在 LiteLLM 中将定时任务池隔离为 `batch-*` 模型组，使用独立 virtual key、team budget、TPM/RPM、fallback 和日志策略。
3. 员工和内部系统发起定时任务时，必须显式选择 `batch-*` 模型组；默认交互模型组不接受批处理 token 或长期无人值守任务。
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
  +--------------+-----------------------------+-------------------+
  |                                            |                   |
  v                                            v                   v
Azure Foundry Claude Pool                Azure Foundry GPT Pool    Vertex Claude via Partner
10 subscriptions                         5 subscriptions           Separate cloud/provider path
Opus/Sonnet/Haiku                        GPT 5.4 / GPT 5.5         Claude Opus/Sonnet/Haiku
  |                                            |
  v                                            v
model_name isolation:                        model_name isolation:
  claude-opus-4-7-grp1: llmpool-sub01,02       gpt-5.5-grp1: llmpool-sub11
  claude-opus-4-7-grp2: llmpool-sub03,04       gpt-5.5-grp2: llmpool-sub12
  claude-opus-4-7-grp3: llmpool-sub05,06       gpt-5.5-grp3: llmpool-sub13
  claude-opus-4-7-grp4: llmpool-sub07,08       gpt-5.5-grp4: llmpool-sub14
  claude-opus-4-7-grp5: llmpool-sub09,10       gpt-5.5-grp5: llmpool-sub15

Scheduled / batch workload pool:
Internal Jobs --> LiteLLM batch-* groups --> Dedicated Foundry endpoints
                                         2 extra subscriptions, isolated keys and logs

Developer workflow:
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
| `claude-opus-4-7-grp{1..5}` | 每组 2 个 Foundry Claude Opus 端点 | 高复杂度任务，5 组隔离 |
| `claude-sonnet-4-6-grp{1..5}` | 每组 2 个 Foundry Claude Sonnet 端点 | 默认 Claude 主力模型，5 组隔离 |
| `claude-haiku-4-5-grp{1..5}` | 每组 2 个 Foundry Claude Haiku 端点 | 低延迟、高频轻量任务，5 组隔离 |
| `gpt-5.5-grp{1..5}` | 每组 1 个 Foundry GPT 5.5 端点 | GPT 主力模型，5 组隔离 |
| `gpt-5.4-grp{1..5}` | 每组 1 个 Foundry GPT 5.4 端点 | GPT 主力模型，5 组隔离 |
| `gpt-5.4-mini-grp{1..5}` | 每组 1 个 Foundry GPT mini 端点 | 快速低成本任务，5 组隔离 |
| `gpt-5.4-nano-grp{1..5}` | 每组 1 个 Foundry GPT nano 端点 | 快速低成本任务，5 组隔离 |
| `DeepSeek-V4-Pro-grp1` | 每组 1 个 Foundry DeepSeek-V4-Pro 端点 | 高质量推理与代码 |
| `DeepSeek-V4-Flash-grp1` | 每组 1 个 Foundry DeepSeek-V4-Flash 端点 | 低延迟推理 |
| `vertex-claude-opus` | Vertex Claude via Partner | Claude 跨云备用（不分组） |
| `vertex-claude-sonnet` | Vertex Claude via Partner | Claude 跨云备用（不分组） |
| `vertex-claude-haiku` | Vertex Claude via Partner | Claude 跨云备用（不分组） |
| `batch-gpt-5.5-grp{1..2}` | 定时任务专用 Foundry GPT 池 | 周期性任务首选 Claude 模型组（独立池已隔离） |
| `batch-gpt-5.4-grp{1..2}` | 定时任务专用 Foundry GPT 池 | 周期性任务首选 Claude 模型组（独立池已隔离） |
| `batch-gpt-5.4-mini-grp{1..2}` | 定时任务专用 Foundry GPT mini 池 | 低成本、高频重复 prompt |
| `batch-gpt-5.4-nano-grp{1..2}` | 定时任务专用 Foundry GPT nano 池 | 低成本、高频重复 prompt |

用户分配到某一组号后，应用层使用对应的 `model_name`（如 `claude-sonnet-4-6-grp1`）发起请求。LiteLLM 的 team/key 配置限定每个用户只能访问其所属组的模型名。

### 6.2 路由、限流与降级

1. 使用 `routing_strategy: simple-shuffle`，并为每个 deployment 设置 `tpm`、`rpm`、`max_parallel_requests`。
2. 将单端点 `tpm` 设置为客户已确认配额的 80% 到 90%，预留平台波动和突发空间。
3. 启用 `enable_weighted_failover: true`，先在同模型组内切换健康端点，再进入跨模型 fallback。
4. 推荐 `num_retries: 2` 或 `3`，并配合 `retry_after`、`allowed_fails`、`cooldown_time`。
5. 对认证错误、权限错误、配额配置错误设置低重试或不重试，避免无效请求放大。
6. 单独配置 `context_window_fallbacks` 和 `content_policy_fallbacks`，不要把所有错误都当作同一种故障。
7. 定时任务必须使用 `batch-*` 模型组和独立 virtual key；生产网关应通过 key 权限、team model allowlist 或应用侧校验，阻止批处理任务调用交互式模型组。
8. 各隔离组的 `fallbacks` 应优先降级到 Vertex Claude（同模型类型，如 `claude-sonnet-4-6-grp{N}` → `vertex-claude-sonnet`），再降级到 GPT（如 `gpt-5.4-mini-grp{N}`），绝不降级到同模型的其他组号——避免违规流量扩散到健康组。该顺序确保 fallback 后模型行为一致性。`content_policy_fallbacks` 同理。

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
3. 对 `gpt-5.4-mini`、`claude-haiku-4-5` 设置默认轻量任务入口。
4. 对 `batch-*` 模型组设置更低默认预算、独立成本中心和任务级标签，避免定时任务挤占交互式研发预算。
5. 将 `spend logs` 与成本中心、项目 ID、应用 ID 关联，支持内部 showback/chargeback。
6. 建立容量日报：TPM 峰值、RPM 峰值、429 次数、fallback 次数、端点冷却次数、平均延迟、用户活跃数、定时任务调用量和批处理失败率。

## 7. Azure 自动化建议

本仓库提供账号池批量创建工具，分为两阶段流程：订阅创建与模型端点部署，便于在权限受限环境中分步测试。

脚本清单：

- **[scripts/create-subscriptions.sh](scripts/create-subscriptions.sh)**：第一阶段，创建 Azure 订阅并输出参数 CSV 文件。需要 EA/MCA billing scope 权限。
  - 用户自行决定在 prefix 参数加入 claude/gpt/ds 字样区分一批订阅将要创建的模型类别，如 `llmpool-claude`，脚本本身不依赖于此逻辑工作，prefix 本身不输出到 CSV；
  - 用户指定 prefix 用于命名订阅、foundry 实例，prefix 在输出 CSV 占一列；
  - 支持正向选择模型类型（model_type, 用参数 `--claude`、`--gpt`、`--deepseek` 激活），指定多个时只有最后一个生效，确保一个订阅中只有一类模型；生效选项在 CSV 中占一列；
  - 订阅名规则为 `{prefix}-{claude|gpt|deepseek}-sub{N}`;
  - 所属管理组为可选参数；location 默认 eastus2；
  - **幂等**：已存在的订阅（按名称匹配）自动跳过创建，支持重复执行以增量补充；
- **[scripts/deploy-models.sh](scripts/deploy-models.sh)**：第二阶段，基于参数 CSV 在各订阅下创建 resource group 和 Foundry 资源并部署模型端点。
  - 基于 `create-subscriptions.sh` 的输出 CSV 读取订阅 ID、订阅名、prefix、模型类型（model_type）、location；
  - 资源组名称固定为 `rg-foundry`，foundry 实例名称为 `fdry-{prefix}-{model_type}-{4 位随机数}`；
  - 输出文件为 CSV 格式，包含全部订阅的全部模型端点、模型名和访问密钥；
  - **幂等**：资源组已存在则复用；Foundry 实例按 `fdry-{prefix}-{model_type}-` 前缀匹配已有实例直接使用；模型端点已存在则打印状态并跳过。支持重复执行以增量开通新模型；
  - **容错**：单个订阅部署失败不影响后续订阅处理，执行结束报告成功/失败统计；
  - 执行前列出待处理订阅清单并要求确认（`--force` 跳过）；
- **[scripts/delete-resources.sh](scripts/delete-resources.sh)**：清理脚本，删除订阅下的资源组 `rg-foundry` 并清除软删除状态，用于回归测试。
  - 执行前列出待处理订阅清单并要求确认；单个订阅失败不影响后续处理；
- **[scripts/test-endpoints.sh](scripts/test-endpoints.sh)**：端点连通性验证脚本，自动遍历创建结果清单并逐一测试模型可访问性。

### 7.1 两阶段部署流程

#### 第一阶段：创建订阅（create-subscriptions.sh）

需要 billing scope 权限，输出 `generated/subscriptions.csv`：

1. 通过 EA/MCA billing scope 调用 Subscription Alias API 创建新订阅。
2. 将新订阅移入指定管理组（可选）。
3. 输出 CSV 参数文件 `./generated/subscriptions.csv`，包含字段 `subscription_id, subscription_name, prefix, model_type, location, anthropic-org, anthropic-industry, anthropic-country`。

#### 第二阶段：部署模型端点（deploy-models.sh）

基于参数 CSV 文件，在每个订阅中执行：

1. 注册必要 resource provider（CognitiveServices、SaaS、MarketplaceOrdering 等）。
2. 创建资源组和 AI Foundry（Cognitive Services AIServices）资源。
3. 按 model_type 部署对应类型的模型端点。(从 CSV 获取 anthropic 有关参数)
4. Claude 模型通过 REST API（api-version `2025-10-01-preview`）部署，包含 `modelProviderData`（organizationName、industry、countryCode，取自 CSV 的 anthropic-org, anthropic-industry, anthropic-country）。
5. GPT 和 DeepSeek 模型通过 `az cognitiveservices account deployment create` 部署。
6. 输出端点、模型名称、访问密钥清单 CSV `./generated/foundry-endpoints.csv`，包含字段 `model_endpoint, model_name, access_key`。

### 7.2 支持的模型

| 模型族 | 可用模型 | 部署格式 | 版本 |
| --- | --- | --- | --- |
| Claude | claude-opus-4-8, claude-opus-4-7, claude-sonnet-4-6, claude-haiku-4-5 | Anthropic | 1, 1, 1, 20251001 |
| GPT | gpt-5.5, gpt-5.4, gpt-5.4-mini, gpt-5.4-nano | OpenAI | 2026-04-24, 2026-03-05, 2026-03-17, 2026-03-17 |
| DeepSeek | DeepSeek-V4-Pro, DeepSeek-V4-Flash | DeepSeek | 2026-04-23, 2026-04-23 |

### 7.3 命令行用法

```bash
# ==================== 第一阶段：创建订阅 ====================
export BILLING_SCOPE="/providers/Microsoft.Billing/billingAccounts/{billing_account}/billingProfiles/{profile}/invoiceSections/{section}"

# 创建 claude 10 个订阅
scripts/create-subscriptions.sh \
  --prefix demopool \
  --claude \
  --anthropic-org "Your Organization Name" \
  --anthropic-industry Manufacturing \
  --anthropic-country SG \
  --count 10 \
  --location eastus2 \
  --billing-scope "$BILLING_SCOPE" \
  --mgmt-group grp-demoai

# ==================== 第二阶段：部署模型 ====================
# 部署 CSV 文件指定端点
scripts/deploy-models.sh \
  --input ./generated/subscriptions.csv

# for test deploy, 100k tpm
scripts/deploy-models.sh \
  --input ./generated/subscriptions.csv
  --tpm 100000

# ==================== 清理与回归 ====================
# 删除所有资源（含软删除清除）
scripts/delete-resources.sh \
  --input ./generated/subscriptions.csv --force

# 验证端点
VERBOSE=true scripts/test-endpoints.sh \
  --input ./generated/foundry-endpoints.csv
```

### 7.4 参数说明

**create-subscriptions.sh**：

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `-p, --prefix` | 资源命名前缀 | `llmpool` |
| `--claude` | 部署 Claude 模型 | — |
| `--gpt` | 部署 GPT 模型 | — |
| `--deepseek` | 部署 DeepSeek 模型 | — |
| `--anthropic-org` | Claude 模型创建参数 organizationName | `Contoso Pte.Ltd` |
| `--anthropic-industry` | Claude 模型创建参数 industry | `Manufacturing` |
| `--anthropic-country` | Claude 模型创建参数 countryCode | `SG` |
| `-n, --count` | 订阅套数 | `10` |
| `-l, --location` | Azure 区域 | `eastus2` |
| `-s, --billing-scope` | EA/MCA 计费范围（必需） | — |
| `-m, --mgmt-group` | 管理组 ID（可选） | — |
| `--dry-run` | 仅打印操作 | — |

**deploy-models.sh**：

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `-i, --input` | 输入 CSV 文件 | `./generated/subscriptions.csv` |
| `-t, --tpm` | 默认 TPM（可选，测试时指定低配额） | — |
| `--force` | 跳过确认 | — |
| `--dry-run` | 仅打印操作 | — |

**delete-resources.sh**：

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `-i, --input` | 输入 CSV 文件 | `./generated/subscriptions.csv` |
| `--force` | 跳过确认 | — |
| `--no-purge` | 不清除软删除 | — |
| `--dry-run` | 仅打印操作 | — |

### 7.5 端点连通性测试

创建完成后使用 `test-endpoints.sh` 验证端点可用性：

```bash
# 测试所有端点
scripts/test-endpoints.sh ./generated/foundry-endpoints.csv

# 显示完整响应
VERBOSE=true scripts/test-endpoints.sh ./generated/foundry-endpoints.csv
```

### 7.6 注意事项

1. 使用 `--dry-run` 模式确认脚本将执行的操作。
2. 在测试订阅中验证 Anthropic Claude 模型的 Marketplace 条款接受、区域可用性和部署 API 兼容性。
3. 确认 billing scope 格式、服务主体权限和订阅配额限制。
4. 部署完成后使用 `test-endpoints.sh` 验证所有端点的连通性和模型可访问性。
5. Foundry 资源删除后有 48 小时软删除窗口期，`delete-resources.sh` 默认执行清除以支持立即重建。
6. Claude 部署使用 REST API（api-version `2025-10-01-preview`）以支持 `modelProviderData` 字段；GPT 和 DeepSeek 使用标准 `az cognitiveservices` CLI。
7. 跨订阅 quota 是共享的（如 GPT GlobalStandard quota 按区域聚合），需确保总部署容量不超过租户级别配额限制。
8. 当 Azure Policy 强制 `disableLocalAuth=true` 时，API Key 不可用。`deploy-models.sh` 会自动为当前用户分配 `Cognitive Services OpenAI User` 角色，端点测试通过 Azure AD Bearer Token 认证。`test-endpoints.sh` 自动识别 JWT token 并使用 `Authorization: Bearer` 头部。
9. **所有脚本支持重复执行（幂等）**：`create-subscriptions.sh` 跳过已存在订阅；`deploy-models.sh` 复用已有资源组和 Foundry 实例，跳过已部署模型；适合增量开通新模型（如在现有订阅上新增 claude-opus-4-8）。
10. 单个订阅的部署失败不会中断整批处理，脚本继续执行后续订阅并在结束时报告成功/失败统计。

### 7.7 实际命令举例

举例如下，Claude、GPT 和 DeepSeek 端点分开创建。Foundry 模型端点 10 组，LiteLLM model_name 5 组，避免一个 model_name 影响全部 foundry 模型端点。

```sh
export BILLING_SCOPE="/providers/Microsoft.Billing/billingAccounts/{_get_real_billingAccounts_}/billingProfiles/{_get_real_billingProfiles_}/invoiceSections/{_get_real_invoiceSections_}"

# 10 个 claude 订阅
scripts/create-subscriptions.sh \
  --prefix demopool2605 \
  --claude \
  --anthropic-org "Contoso" \
  --anthropic-industry Manufacturing \
  --anthropic-country SG \
  --count 10 \
  --location eastus2 \
  --billing-scope "$BILLING_SCOPE" \
  --mgmt-group grp-demoai

# 10 个 claude 端点
scripts/deploy-models.sh \
  --input ./generated/subscriptions.csv

# 验证
VERBOSE=true scripts/test-endpoints.sh ./generated/foundry-endpoints.csv

# 增量开通：新增模型后重新执行，已有资源自动复用、已部署模型自动跳过
scripts/deploy-models.sh \
  --input ./generated/subscriptions.csv

# 回归测试：删除后重建
scripts/delete-resources.sh --input ./generated/subscriptions.csv --force

scripts/deploy-models.sh \
  --input ./generated/subscriptions.csv
```

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

## 9. GitHub Copilot 方案（独立文档）

GitHub Copilot 相关的完整内容（Copilot 桥接 Claude Code、请求审计留存、MCP 配置、企业部署建议）已汇总至独立文档：**[GitHub Copilot：中国区客户 Vibe Coding 首选推荐方案](github-copilot-solution.md)**。

该文档将 GitHub Copilot 定位为中国区客户 Vibe Coding 首选方案——不仅是模型 API，而是 Harness + 模型 API 的完整 Vibe Coding 解决方案。与本文档描述的 LiteLLM + Foundry 主方案互补并行。

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
8. Copilot 留存验证：抽样确认 IDE 请求经代理写入 Elasticsearch/SIEM，证书、代理认证、用户映射和脱敏策略符合安全评审要求（详见 [github-copilot-solution.md](github-copilot-solution.md)）。
10. Copilot 桥接 Claude Code 验证：确认 copilot-api 本地代理启动后 Claude Code 可正常调用模型；配合 mitmproxy 时验证 prompt 完整留存（详见 [github-copilot-solution.md](github-copilot-solution.md)）。

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
9. GitHub Copilot Extensions / Agent 文档：[Using Copilot's LLM for your agent](https://docs.github.com/en/copilot/how-tos/build-copilot-extensions/building-a-copilot-agent-for-your-copilot-extension/using-copilots-llm-for-your-agent)、Copilot API 调用的官方支持声明。
10. `copilot-api` npm 包与 [feiskyer/claude-code-settings](https://github.com/feiskyer/claude-code-settings/blob/main/guidances/github-copilot.md)：Claude Code 接入 GitHub Copilot 的配置指南、Device Flow 认证、可用模型列表。
