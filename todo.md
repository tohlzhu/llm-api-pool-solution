# TODO

按照下面罗列的要求更新设计文件 `llm-api-pool-solution.md` 和其他相关脚本、配置示例代码。

## 更新要求

1. 文档涉及 GPT 模型的地方，开发用的统一建议 GPT 5.4/5.5，处理数据的低成本模型建议 gpt-nano/gpt-mini，请据此更新所有描述和脚本所举例的模型；
2. litellm 有 fallback 的配置项，可以设计为首选 foundry Claude 为后端端点的模型其 fallback 模型为 GCP Claude 端点，这样模型类型一致，避免 fallback 后工作异常，也保证了优先使用 foundry 模型；请按照这个逻辑更新全文的多级备份逻辑，更新脚本、配置示例；
3. github copilot 还有一个特殊用法，参考这个链接 [Claude Code with GitHub Copilot as Model Provider](https://github.com/feiskyer/claude-code-settings/blob/main/guidances/github-copilot.md#claude-code-with-github-copilot-as-model-provider)，如果客户需要继续使用 Claude Code 作为 Harness 方案，可以考虑通过此链接的方法将本地 github copilot 的模型接口桥接到本地 Claude Code 环境，事实上这个也可以支持接入到 OpenClaw 一类的本地 Agent 方案，但是都需要客户有 github copilot 账号，且只能服务于一个终端，以避免 github copilot 服务器侧认定行为异常而 block 账号。请把这个用法作为单独一个章节体现在解决方案中，配合 mitmproxy 实现 prompt 留存，此方法应视为与 Claude Code + Litellm + Foundry Claude endpoint 同一个级别的 vibe coding 软件解决方案。（注意此用法相对特殊，请增加一个专门的架构图表达意思）

## 输出文件

如有必要，更新相关 markdown 文件或按需调整配置示例文件。

请注意发挥主动性寻找最新素材，并通过多个渠道核实准确性。所有脚本和配置均使用占位符，不写入真实租户 ID、密钥、token 或客户敏感信息。
