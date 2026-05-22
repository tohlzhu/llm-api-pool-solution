# TODO

按照下面罗列的要求在现有设计文件 `llm-api-pool-solution.md` 基础上增加描述，注意酌情更新不同段落。

## 方案要求

1. 考虑到 Claude 模型访问时有严格的服务器端安全检查规则，大量重复 prompt 可能导致云端安全扫描判定该端点用于非法业务进而关闭访问权限，需要在账号池上增加冗余设计：
    - 为客户业务中的定时任务创建单独的账号池，实现方面需要增加专门的若干订阅（比如5个）开出 Claude/GPT 模型的端点，在 litellm 中也应该隔离出独立的 group 用于定时任务；
    - 在文档中增加建议，要求客户向用户宣传执行定时任务时要指定上述 litellm 中的特定 group，并且原则上要用 gpt-nano/gemini-flash/claude-haiku 这类低成本模型；
2. litellm 中的日志在 pg 数据库保存数量太多会严重影响性能，建议创建 DMS 定期任务在夜间把30天以上数据转移到 clickhouse/elasticsearch；
3. 客户需要对 github copilot 中的所有请求做留存，以便审计和后期做数据分析，这个可以通过 [mitmproxy-copilot](https://github.com/nikawang/mitmproxy-copilot) 实现，请阅读该项目介绍信息，把原理和操作方法、项目地址放在 solution 中做单独章节；

## 输出文件

如有必要，更新以下文件或按需增加配置示例文件，

1. `llm-api-pool-solution.md`：主解决方案文档，Markdown 格式，中文。
2. `scripts/create-foundry-pool.sh`：Azure CLI/Linux 参考自动化脚本。
3. `config/litellm-config.example.yaml`：LiteLLM 示例配置。
4. `.vscode/mcp.example.json`：VS Code / GitHub Copilot 本地 MCP 示例配置。

请注意发挥主动性寻找最新素材，并通过多个渠道核实准确性。所有脚本和配置均使用占位符，不写入真实租户 ID、密钥、token 或客户敏感信息。
