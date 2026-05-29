# TODO

~~按照下面罗列的要求更新设计文件 `llm-api-pool-solution.md` 和其他相关脚本、配置示例代码。~~ ✓ Done

## 环境说明

1. 当前工作环境的 azure cli 登录了两个 azure 订阅，分别是 "ME-MngEnvMCAP236878-zhuhonglei-1" (isDefault: true) 和 "ME-MngEnvMCAP012397-zhuhonglei-1"，两个订阅你都有权限创建 foundry、foundry 下的任何端点（因为我没有 Claude quota 可用，Claude 模型端点都会创建失败；gpt-5.4/DeepSeek-V4-Pro 模型都可以创建，注意创建时候 tpm 固定设置为 100k）；
2. 当前环境的 azure cli 所登录的 account 无权限创建新的订阅；

## 更新要求

1. 在实际运行 `scripts/deploy-models.sh` 时（输入为 `generated/subscriptions.csv` 输出如下），我发现如果在 csv 第一个订阅上创建失败了（claude 我没权限），脚本就不执行第二个订阅上的部署了，这与期望不一致，请检查、修正是我的 csv 文件写的不对？还是代码逻辑没有继续处理？需要能够继续在后续订阅上执行部署，即便都是失败的；在部署脚本刚一开始时列出计划处理多少条记录（列出订阅名），让我确认或取消；

```
azureuser@vm-dev-jpe-001:/data/github/llm-api-pool-solution$ ./scripts/deploy-models.sh --input ./generated/subscriptions.csv --tpm 100000
[01:04:08] Validating Azure CLI login...
[01:04:08] === Model Deployment ===
[01:04:08] Input file:     ./generated/subscriptions.csv
[01:04:08] TPM override:   100000
[01:04:08] Dry run:        false
[01:04:08] Output dir:     ./generated
[01:04:08] ========================
[01:04:08] === Processing: ME-MngEnvMCAP012397-zhuhonglei-1 (sub=7c199164-eb84-4cfb-be5a-17bdd19bcf3b, type=claude) ===
[01:04:10]   Microsoft.CognitiveServices: already registered
[01:04:11]   Microsoft.MachineLearningServices: already registered
[01:04:11]   Microsoft.SaaS: already registered
[01:04:13]   Microsoft.MarketplaceOrdering: already registered
[01:04:13]   Creating resource group: rg-foundry (location: eastus2)
[01:04:19]   Creating Foundry resource: fdry-apipool2605-claude-8014
[01:05:16]   Foundry resource: fdry-apipool2605-claude-8014
[01:05:17]   Deploying Claude: claude-opus-4-8 (version=1, capacity=100)
Bad Request({"error":{"code":"InsufficientQuota","message":"This operation require 100 new capacity in quota Tokens Per Minute (thousands) - Claude Opus 4.8, which is bigger than the current available capacity 0. The current quota usage is 0 and the quota limit is 0 for quota Tokens Per Minute (thousands) - Claude Opus 4.8."}})
[01:05:20]   WARNING: Failed to deploy claude-opus-4-8 (may require Marketplace acceptance or quota)
[01:05:21]   Deploying Claude: claude-opus-4-7 (version=1, capacity=100)
Bad Request({"error":{"code":"InsufficientQuota","message":"This operation require 100 new capacity in quota Tokens Per Minute (thousands) - Claude Opus 4.7, which is bigger than the current available capacity 0. The current quota usage is 0 and the quota limit is 0 for quota Tokens Per Minute (thousands) - Claude Opus 4.7."}})
[01:05:23]   WARNING: Failed to deploy claude-opus-4-7 (may require Marketplace acceptance or quota)
[01:05:24]   Deploying Claude: claude-sonnet-4-6 (version=1, capacity=100)
Bad Request({"error":{"code":"InsufficientQuota","message":"This operation require 100 new capacity in quota Tokens Per Minute (thousands) - Claude Sonnet 4.6, which is bigger than the current available capacity 0. The current quota usage is 0 and the quota limit is 0 for quota Tokens Per Minute (thousands) - Claude Sonnet 4.6."}})
[01:05:26]   WARNING: Failed to deploy claude-sonnet-4-6 (may require Marketplace acceptance or quota)
[01:05:27]   Deploying Claude: claude-haiku-4-5 (version=20251001, capacity=100)
Bad Request({"error":{"code":"InsufficientQuota","message":"This operation require 100 new capacity in quota Tokens Per Minute (thousands) - Claude Haiku 4.5, which is bigger than the current available capacity 0. The current quota usage is 0 and the quota limit is 0 for quota Tokens Per Minute (thousands) - Claude Haiku 4.5."}})
[01:05:29]   WARNING: Failed to deploy claude-haiku-4-5 (may require Marketplace acceptance or quota)
[01:05:30] === Deployment complete ===
[01:05:30] Endpoint inventory: ./generated/foundry-endpoints.csv
[01:05:30]   4 model endpoints deployed

azureuser@vm-dev-jpe-001:/data/github/llm-api-pool-solution$ ./scripts/delete-resources.sh --input ./generated/subscriptions.csv
[01:24:15] === Resource Deletion ===
[01:24:15] Input file: ./generated/subscriptions.csv
[01:24:15] Dry run:    false
[01:24:15] Force:      false
[01:24:15] Purge:      true
[01:24:15] Subscriptions to clean (rg-foundry):
[01:24:15]   ME-MngEnvMCAP012397-zhuhonglei-1 (7c199164-eb84-4cfb-be5a-17bdd19bcf3b)

WARNING: This will delete resource group 'rg-foundry' in 1 subscription(s).
Press Enter to continue, or Ctrl+C to abort...

[01:24:50] --- Subscription: ME-MngEnvMCAP012397-zhuhonglei-1 (7c199164-eb84-4cfb-be5a-17bdd19bcf3b) ---
[01:24:51]   Deleting resource group: rg-foundry
[01:24:52] Waiting for resource group deletions to complete...
[01:26:00]   ME-MngEnvMCAP012397-zhuhonglei-1: rg-foundry deleted
[01:26:00] Purging soft-deleted Cognitive Services accounts...
[01:26:03]   ME-MngEnvMCAP012397-zhuhonglei-1: purging 10 soft-deleted account(s)...
[01:26:03]     Purging: fdry-aipool2605-gpt-6264
[01:26:05]     Purging: fdry-aipool2605-deepseek-9839
[01:26:06]     Purging: fdry-aipool2605-claude-4670
[01:26:08]     Purging: fdry-aipool2605-gpt-5974
[01:26:10]     Purging: fdry-apipool2605-deepseek-4232
[01:26:11]     Purging: fdry-apipool2605-deepseek-7719
[01:26:11]     Purging: fdry-aipool2605-gpt-0467
[01:26:13]     Purging: fdry-aipool2605-gpt-6640
[01:26:14]     Purging: fdry-aipool2605-deepseek-9511
[01:26:15]     Purging: fdry-apipool2605-claude-8014
[01:26:17] === Deletion complete ===
```

2. `scripts/delete-resources.sh` 删除脚本也调整为列出有多少条记录待处理（列出订阅名），并确保全部被处理；
3. 用户可能需要增量的开通模型，比如一开始只有 claude-opus-4-7，某天增加了 claude-opus-4-8，需要在原有订阅清单上增加开通 claude-opus-4-8 。基于这个逻辑，请修订代码，使 `scripts/deploy-models.sh` 创建计划中的资源组及 foundry 实例时如果资源已经存在就直接使用，**注意 foundry 的实例名称有随机数字，检查 `fdry-{prefix}-{model_type}-` 这部分能匹配就直接使用，不要被随机数造成未识别而重复创建**；创建计划中的模型端点如果存在，就打印端点状态，然后跳过，继续做下一个；
4. 上述逻辑同理，检查 `scripts/create-subscriptions.sh` 的代码，调整为如果存在 `{prefix}-{claude|gpt|deepseek}-sub{N}` 匹配的订阅，就跳过创建，继续执行下一个创建；（这个脚本是测不了的，做内容检查核实就行）
5. 总体上希望脚本能够支持重复执行，以便增量开通资源，请检查所有逻辑，更新代码和文档描述。

## 输出文件

如有必要，更新相关 markdown 文件或按需调整配置示例文件。

请注意测试，注意发挥主动性寻找最新素材，并通过多个渠道核实准确性。所有脚本和配置均使用占位符，不写入真实租户 ID、密钥、token 或客户敏感信息。
