# TODO

按照下面罗列的要求更新设计文件 `llm-api-pool-solution.md` 和其他相关脚本、配置示例代码。

## 环境说明

1. 当前环境 azure cli 登录的 Azure 订阅 "ME-MngEnvMCAP236878-zhuhonglei-1" (isDefault: true) 和 "ME-MngEnvMCAP012397-zhuhonglei-1" 都有权限创建 foundry、foundry 下的任何端点，但是没有 Claude quota 可用，Claude 模型端点都会创建失败；gpt-5.4/DeepSeek-V4-Pro 模型都可以创建；
2. 当前环境的 azure cli 所登录的 10 个订阅 `adai2605-claude-sub{1..10}` 用于开 Claude 模型，7 个订阅 `adai2605-gpt-sub{1..7}` 用于开 gpt 模型；
3. 运行 `az account list` 可以查到订阅基本信息，目前所有 azure cli 下登录的账号都没有权限创建新订阅；
4. 注意如果测试创建 foundry 下的模型，其端点参数 tpm 固定设置为 100k；

## 更新要求

1. 我用 ` VERBOSE=true ./scripts/test-endpoints.sh ./generated/foundry-endpoints.csv` 得到以下输出，其中 claude-opus-4-8 的响应 "Access denied due to invalid subscription key or wrong API endpoint." 不符合预期，请基于环境说明中的例子重新调试脚本。

## 注意事项

如有必要，更新相关 markdown 文件或按需调整配置示例文件。

请注意测试，注意发挥主动性寻找最新素材，并通过多个渠道核实准确性。所有脚本和配置均使用占位符，不写入真实租户 ID、密钥、token 或客户敏感信息。
