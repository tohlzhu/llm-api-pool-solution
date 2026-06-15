# TODO

按照下面罗列的要求更新设计文件 `llm-api-pool-solution.md` 和其他相关脚本、配置示例代码。

## 环境说明

1. 当前 shell 环境登录了一个 azure 账号，订阅名为 ME-MngEnvMCAP012397-zhuhonglei-1，可以新建资源组 `rg-dev3`，在资源组下创建新的 foundry 实例、新的 model endpoint（注意由于 quota 不够，创建 Claude 相关模型都会失败）。
2. 上述 azure 账号不能新建订阅，如果需要调试创建 foundry、model endpoint/model deployment 的行为，可以在上述订阅中执行；如果需要调试创建订阅的功能请 **务必跳过，以基于文档的分析为主**。

## 更新要求

我收到微软通知如下，

```txt
As of May 6th, Global and Data Zone Standard deployments will utilize one pool per deployment type for consumption. This update helps Foundry scale model availability across more regions and launch new models faster, while maintaining capacity experience across customers. [Click here](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/quotas-limits) for more information. 
```

请阅读通知和其中的网页链接，分析当前项目文档和代码、脚本，告诉我当前创建模型端点的方法是否正确？尤其是当前会指定 region，而通知提到的 `Global Standard` 方式似乎不需要指定区域。请首先回答问题，再根据我的指令决定是否修改代码做适配。

## 注意事项

如有必要，更新相关 markdown 文件或按需调整配置示例文件。

请注意测试，注意发挥主动性寻找最新素材，并通过多个渠道核实准确性。所有脚本和配置均使用占位符，不写入真实租户 ID、密钥、token 或客户敏感信息。
