# 架构图 SVG 设计规格

日期：2026-08-02
适用任务：`todo.md` — 为 `llm-api-pool-solution.md` 增加 SVG 架构图

## 1. 目标

为方案文档提供两张手写 SVG 架构图，表达三个设计意图：

1. AI gateway（LiteLLM）+ Azure Foundry 多订阅多端点的分层供应结构；
2. 端点分组（`model_name` 5 组隔离）；
3. 组间 fallback 顺序带来的健壮性与故障隔离能力。

图中所有文字使用英文（避免渲染环境缺少中文字形导致显示问题）。文档正文仍为中文。

## 2. 交付物

| 文件 | 内容 | 嵌入位置 |
| --- | --- | --- |
| `assets/architecture-overview.svg` | 分层供应：消费方 → LiteLLM 网关 → 多订阅 Foundry 池 + Vertex 备用 | `llm-api-pool-solution.md` §5 目标架构，置于现有 `text` 块之前 |
| `assets/architecture-isolation-fallback.svg` | 5 组 `model_name` 隔离、故障影响范围对比、fallback 优先级 | `llm-api-pool-solution.md` §4.2.1，置于"隔离效果"表之后、"配套配置示例见…"之前 |

文档改动：

1. §5 插入总览图；现有 ASCII `text` 块保留，包进 `<details><summary>纯文本等价描述</summary>`，作为无图环境（终端、grep、纯文本 diff）的降级路径。
2. §4.2.1 插入隔离图。
3. `README.md` 方案文件清单增加两个 SVG 条目。
4. `CLAUDE.md` 与 `AGENTS.md` 的 supporting artifacts 说明增加 `assets/*.svg`，并注明架构图需与文档同步维护。

不改动 `scripts/*.sh` 与 `config/litellm-config.example.yaml`：两张图描述的是这些文件已实现的行为，不引入新配置项。

## 3. 技术约束

GitHub 通过 `<img>` / `![]()` 渲染 `.svg` 时使用 SVG secure static mode：

1. SVG 内部的 `<style>` 块有效，可用 class 组织样式；
2. `<script>`、外部字体、外部图片引用被阻断；
3. `prefers-color-scheme` 跟随操作系统主题，不跟随 GitHub 主题开关。

因此配色必须在浅色与深色背景下同时可读：每个图元使用显式浅色填充 + 饱和描边 + 近黑文字，并在最底层铺一个中性画布矩形，使深色主题下仍保持"纸面打印"的对比关系。字体使用系统字体栈并带通用兜底，不加载外部字体。

## 4. 总览图设计

画布约 1480×1080，自上而下五个带（band）：

1. **Consumers**：Developer Apps / Internal Tools / Agents（5 teams，约 1000 员工）、Scheduled Jobs / Batch Workloads、Employee IDE（VS Code + Copilot）。前两者经 virtual key / batch key 进入网关；IDE 走独立侧道，明确标注不是 LiteLLM 后端（对应 §4.5）。
2. **Gateway**：LiteLLM API Gateway on AKS，列出 auth/keys/teams、model_name isolation、simple-shuffle、weighted failover、cooldown/retry、full request-response logging；右侧并列运维平面（Redis、PostgreSQL、Key Vault、Monitor）。
3. **Model names（用户可见）**：`claude-*-grp1..5`、`gpt-*-grp1..5`、`batch-gpt-*-grp1..2`、`DeepSeek-*-grp1`、`vertex-claude-*`。
4. **Supply pools**：
   - L1/L2 Foundry Claude，10 个订阅、30 个端点，5 条分组带各覆盖 2 个订阅；
   - L3 Foundry GPT，5 个订阅、20 个端点，5 条分组带各覆盖 1 个订阅；
   - Batch 池，2 个订阅，独立框、独立 key 箭头；
   - DeepSeek，1 个订阅；
   - L4 Vertex Claude via Partner，跨云备用。
5. **Legend + 脚注**：图例，以及 `eastus2` / `GlobalStandard` / `fdry-{subscription_name}` / `proj-{subscription_name}` 命名与区域说明。

每个订阅框标注订阅名模式与端点数（例如 `{prefix}-claude-sub01` / `3 ep`）。分组带绘制为成员订阅**背后**的浅色圆角带，使"Claude 每组 2 订阅、GPT 每组 1 订阅"的容量差异无需额外文字即可看出。

## 5. 隔离与 fallback 图设计

画布约 1480×900，左右对比 + 下方 fallback 阶梯：

1. **左侧面板（约 40%）"Without isolation"**：单一 `claude-sonnet-5` 名称下挂 10 个订阅端点；一次政策命中导致全部 10 个端点受影响，所有 team 失去该模型。
2. **右侧面板（约 60%）"With 5 isolation groups"**：5 条分组带各覆盖 2 个订阅，grp1 标记为 `✗ SUSPENDED`，其余标记 `✓ healthy`；标注影响范围为 10 个端点中的 2 个、80% 容量正常、仅 team A 受影响。
3. **Fallback 阶梯**（针对受影响的 grp1）：
   - ① 同组内健康端点优先（grp1 内 s01 → s02）；
   - ② 同模型类型跨云 → `vertex-claude-sonnet`；
   - ③ 跨模型、同组号 → `gpt-5.5-grp1`；
   - ╳ 禁止 → `claude-sonnet-5-grp2..5`，以红色划除箭头绘制，标注原因为避免"带病"流量扩散到健康组。
4. **Footer**：审计要求——每请求记录 `model_name` 组号与用户标识。

阶梯顺序须与 `config/litellm-config.example.yaml` 中 `fallbacks:` 的实际顺序一致。禁止跨组的划除箭头是本图最关键的标记，对应 §6.2 第 8 条的文字表述。

## 6. 视觉系统

| 角色 | 填充 / 描边 | 应用对象 |
| --- | --- | --- |
| Consumers | `#eef2ff` / `#4f5bd5` | apps、jobs、IDE |
| Gateway | `#e0f2fe` / `#0369a1` | LiteLLM、运维平面 |
| Claude supply | `#fff1e6` / `#c2570e` | Claude 订阅与分组带 |
| GPT supply | `#e7f7ef` / `#15803d` | GPT 订阅与分组带 |
| Batch | `#f3e8ff` / `#7e22ce` | batch 订阅 |
| DeepSeek / Vertex | `#f1f5f9` / `#475569` | 备用渠道 |
| Fault / blocked | `#fee2e2` / `#b91c1c` | suspended 状态、禁止箭头 |

画布底色 `#f8fafc`。字体 `'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif`。标签最小 12px，框标题 15px 以上。

结构规则：

1. 单个 `<style>` 块，class 驱动，颜色与线宽只声明一次；
2. 坐标对齐 20px 网格；
3. 箭头统一使用一组 `<marker>`：`arrow-normal`、`arrow-fallback`、`arrow-blocked`；
4. `role="img"` 加 `<title>` / `<desc>`，提供可访问性描述；
5. 不使用 `<script>`、`<foreignObject>`、外部引用。

## 7. 验证方案

交付前四道关卡：

1. **XML 良构**：`python3 -c "import xml.etree.ElementTree as E; E.parse('<file>')"` 对两个文件均通过。
2. **安全性 grep**：确认不含 `<script`、`foreignObject`，且除 xmlns 声明外无 `http://` / `https://` 引用。
3. **渲染检查**：用 Playwright 自带 Chromium 无头渲染为 PNG，分别输出原始尺寸与缩放到 800px 宽两种版本；人工查看是否存在图元重叠、文字截断、箭头未命中目标。
4. **Rubber duck 比对**：重读 §4.2.1、§4.3、§4.4、§4.6、§6.1 及配置文件 `fallbacks:` 块，逐项核对图中的数量、模型名、分组映射与 fallback 跳转，重点包括：
   - 订阅数量 10（Claude）/ 5（GPT 交互）/ 2（batch）/ 1（DeepSeek）；
   - 模型名 `claude-opus-4-8`、`claude-sonnet-5`、`claude-haiku-4-5`、`gpt-5.5`、`gpt-5.6-terra`、`gpt-5.6-sol`、`gpt-5.6-luna`、`DeepSeek-V4-Pro`、`DeepSeek-V4-Flash`；
   - 命名规则 `fdry-{subscription_name}` / `proj-{subscription_name}`；
   - fallback 绝不跨同模型其他组号。

本仓库无构建系统与测试套件，上述检查逐文件手工执行，与 `CLAUDE.md` 的 Validation Commands 风格一致。

## 8. 非目标

1. 不引入图表生成脚本或构建步骤（SVG 本身即交付物，保持仓库无构建系统的现状）。
2. 不修改部署脚本与 LiteLLM 配置示例的任何功能行为。
3. 不在图中体现受限开放模型。
4. 不写入真实租户 ID、订阅 ID、密钥、端点；订阅名一律使用 `{prefix}` 占位形式。
