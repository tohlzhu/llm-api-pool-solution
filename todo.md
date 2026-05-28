# TODO

按照下面罗列的要求更新设计文件 `llm-api-pool-solution.md` 和其他相关脚本、配置示例代码。

## 环境说明

1. 当前工作环境的 azure cli 登录了两个 azure 订阅，分别是 "ME-MngEnvMCAP236878-zhuhonglei-1" (isDefault: true) 和 "ME-MngEnvMCAP012397-zhuhonglei-1"，两个订阅你都有权限创建 foundry、foundry 下的任何端点（因为我没有 Claude quota 可用，Claude 模型端点都会创建失败；gpt-5.4/DeepSeek-V4-Pro 模型都可以创建，注意创建时候 tpm 固定设置为 100k）；
2. 当前环境的 azure cli 所登录的 account 无权限创建新的订阅；
3. 我更新了 `llm-api-pool-solution.md`，订阅和端点的组合修改为每个订阅创建单独的一组端点（ 一组的定义为 Claude 全部模型，或 GPT 全部模型，或 DeepSeek 全部模型），从而避免单个订阅下某渠道的模型被 Block，但是同订阅有其他模型开通，导致无法简单删除订阅，调整为单订阅只提供单一渠道的模型可以规避这个问题；
4. 我删除了上次代码生成的 script/ 脚本，请按照主文档的业务描述重新实现所有脚本；**注意你可以访问的两个订阅都有 policy 阻止 key based access，所以无法验证用 key 访问模型端点的效果，（有可能用 az 命令获取临时 key 可以访问）如果访问不了考虑用 az 查询端点资源状态代替测试；

## 更新要求

1. 基于环境说明，请基于 `llm-api-pool-solution.md` 描述的行为重新实现 scripts/ 下的 4 个脚本；
2. `scripts/create-subscriptions.sh` 因为无法实际测试，你实现后只做代码检查，注意与 Azure 文档核对，尽可能确保正确；
3. `scripts/deploy-models.sh` 需要你实现后进行完整的测试，请基于 `az account list` 看到的两个订阅构造 `generated/subscriptions.csv` 来驱动测试过程，修正所有逻辑，注意做回归验证；
4. `delete-resources.sh` 删除脚本要确保可以实际工作；
5. 测试过程涉及前缀用 `aipool2605`，其他你自己选命名就行；环境中的两个订阅的 tpm quota 有限，涉及指定 tpm 时候全部指定为 100k tpm，否则你创建不了那么多端点；**注意 claude/gpt/deepseek 端点都要测试到，你可以构造三个 `subscriptions.csv` 来实现**
6. github copilot 的行为比较特殊，与账号池本身逻辑不一样，把相关全部内容单独拆分一个 md 文件来描述，在 `llm-api-pool-solution.md` 中将 github copilot 的描述全部剥离，汇总到这个单独的 GitHub copilot 描述文件中，并在 `llm-api-pool-solution.md` 引用它，将它表述为中国区客户 vibe coding 首选推荐方案（但这个方案不是 模型 API，是一种 Harness + 模型 API 的完整 Vibe Coding 方案），务必查找 github copilot 最新官方素材完善表述内容；
7. 现在主文档 `llm-api-pool-solution.md` 的订阅、端点组合模式、litellm 模型分配方式和 model_name 命名都进行了修改，但是代码、脚本、配置文件示例还没更正，请按照主文档表述的意图更新所有代码、脚本、配置文件示例，**务必多角度检查核实，确保与主文档意图一致**；
8. 但是 `scripts/test-endpoints.sh` 要基于 curl + key 的方式测试端点状态，最终用户是能够执行这个操作的，你如果用 az 命令拿到临时 key 可能也能测通，如果确实做不到就做代码审查即可。

## 输出文件

如有必要，更新相关 markdown 文件或按需调整配置示例文件。

请注意测试，注意发挥主动性寻找最新素材，并通过多个渠道核实准确性。所有脚本和配置均使用占位符，不写入真实租户 ID、密钥、token 或客户敏感信息。
