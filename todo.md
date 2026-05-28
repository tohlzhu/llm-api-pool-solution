# TODO

按照下面罗列的要求更新设计文件 `llm-api-pool-solution.md` 和其他相关脚本、配置示例代码。

## 环境说明

1. 当前工作环境的 azure cli 登录了两个 azure 订阅，分别是 "ME-MngEnvMCAP236878-zhuhonglei-1" (isDefault: true) 和 "ME-MngEnvMCAP012397-zhuhonglei-1"，两个订阅你都有权限创建 foundry、foundry 下的任何端点（因为我没有 Claude quota 可用，Claude 模型端点都会创建失败；gpt-5.4/DeepSeek-V4-Pro 模型都可以创建，注意创建时候 tpm 固定设置为 100k）；
2. 当前环境的 azure cli 所登录的 account 无权限创建新的订阅；

## 更新要求

1. 我实际跑 deploy_models.sh 脚本时候发现创建完的foundry服务，我从 web portal 进去看到提醒：`未获授权: 已禁用对 API 密钥的访问，并且该帐户缺少聊天完成权限。你将需要认知服务 OpenAI 用户角色或更高版本。了解详细信息 `，请帮我查询如何避免这类问题。
2. 我发现 deploy_models.sh 处理 generated/subscriptions.csv 时候只处理了第一行就突出脚本了，是怎么回事？请测试、修复。
3. 注意测试要用 quota 100k。


## 输出文件

如有必要，更新相关 markdown 文件或按需调整配置示例文件。

请注意测试，注意发挥主动性寻找最新素材，并通过多个渠道核实准确性。所有脚本和配置均使用占位符，不写入真实租户 ID、密钥、token 或客户敏感信息。
