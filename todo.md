# TODO

按照下面罗列的要求更新设计文件 `llm-api-pool-solution.md` 和其他相关脚本、配置示例代码。

## 环境说明

1. 当前工作环境的 azure cli 登录了两个 azure 订阅，分别是 "ME-MngEnvMCAP236878-zhuhonglei-1" (isDefault: true) 和 "ME-MngEnvMCAP012397-zhuhonglei-1"，两个订阅你都有权限创建 foundry、foundry 下的任何端点（因为我没有 Claude quota 可用，Claude 模型端点都会创建失败；gpt-5.4/DeepSeek-V4-Pro 模型都可以创建，注意创建时候 tpm 固定设置为 100k）；
2. 当前环境的 azure cli 所登录的 account 无权限创建新的订阅；

## 更新要求

1. `scripts/deploy-models.sh` 中大约第 340 行用 anthropic_org 给创建 claude 模型的参数 modelProviderData/organizationName 赋值，以及这里也填写了 industry 和 countryCode ，但是我在 azure portal 中没找到 anthropic_org 的赋值来源。请尝试用 az 命令，从当前环境的一个订阅中提取正确的 organizationName 和 countryCode 赋值；
2. 如果上述操作能成功，修改 deploy-models.sh 代码，实现如果用户不在 csv 指定 anthropic 的这三个参数就提取当前操作的订阅的正确属性填充赋值（industry 用 Manufacturing ），并打印告知用户实际赋值内容；
3. 如果 1 的操作不成功，不要修改任何代码和文件，告知我即可。

## 注意事项

如有必要，更新相关 markdown 文件或按需调整配置示例文件。

请注意测试，注意发挥主动性寻找最新素材，并通过多个渠道核实准确性。所有脚本和配置均使用占位符，不写入真实租户 ID、密钥、token 或客户敏感信息。
