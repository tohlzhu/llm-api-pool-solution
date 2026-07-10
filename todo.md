# TODO

按照下面罗列的要求更新设计文件 `llm-api-pool-solution.md` 和其他相关脚本、配置示例代码。

## 环境说明

1. 当前 shell 环境登录了一个 azure 账号，订阅名为 ME-MngEnvMCAP012397-zhuhonglei-1，可以新建资源组 `rg-dev3`，在资源组下创建新的 foundry 实例、新的 model endpoint（注意由于 quota 不够，创建 Claude 相关模型都会失败）。
2. 上述 azure 账号不能新建订阅，如果需要调试创建 foundry、model endpoint/model deployment 的行为，可以在上述订阅中执行；如果需要调试创建订阅的功能请 **务必跳过，以基于文档的分析为主**。
3. 代码 'scripts/create-subscriptions.sh' 已经用有权限的 azure 账户测试通过，可以正常工作。

## 更新要求

1. 'scripts/deploy-models.sh' 创建模型端点时会创建 foundry 实例和模型端点本身，但是由于 foundry 产品的更新，现在我打开 Azure foundry portal 页面进入 foundry 实例时，页面会提示必须创建 foundry project 才能继续查看端点。请检查 Azure 最新文档和 API，搞清楚如何在创建模型端点前用脚本创建 foundry project，并更新代码实现此行为。
2. 批量创建的 subscription 和 foundry resource 和 foundry project 命名需要有关联度，否则从 azure portal UI 列表中很难定位某个 foundry project 属于哪个 subscription。解决思路：由于现在代码逻辑会保证每个订阅下只有一个 foundry resource 对象，所以命名方面可以让订阅名贯穿 foundry resource 和 project，比如 subscription 'adai2605-gpt-sub1' 对应 foundry resource 'fdry-adai2605-gpt-sub1' 对应 foundry project 'proj-adai2605-gpt-sub1' ，这种方法去除了 foundry resource 中随机命名部分，靠订阅名的唯一性保证 foundry 各种命名的唯一。请按这个思路更新脚本涉及的命名逻辑。
2. OpenAI 新发布了 gpt-5.6-terra/gpt-5.6-sol/gpt-5.6-luna 模型，Anthropic 新发了模型 claude-sonnet-5，请更新 deploy-models.sh 创建的模型列表，去掉 claude-opus-4-7/claude-sonnet-4-6 ，新增 claude-sonnet-5，去掉 gpt-5.4/gpt-5.4-mini/gpt-5.4-nano ，新增 gpt-5.6-terra/gpt-5.6-sol/gpt-5.6-luna ，注意同步更新所有相关脚本代码和文档（ 'llm-api-pool-solution.md' 和 'scripts/*' 和配置文件示例）。**由于你的训练数据不包含最新的模型知识，请搜索 gpt-5.6 和 claude sonnet 5 的文档来了解其产品定位。Anthropic 还发布了模型 Mythos 和 Fable 5，这两个模型属于受限开放，不需要在文档、代码中做任何体现。**

## 注意事项

如有必要，更新相关 markdown 文件或按需调整配置示例文件。

请注意测试，注意发挥主动性寻找最新素材，并通过多个渠道核实准确性。所有脚本和配置均使用占位符，不写入真实租户 ID、密钥、token 或客户敏感信息。
