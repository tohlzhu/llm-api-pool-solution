#!/usr/bin/env bash
# env.example.sh — LiteLLM 网关所需环境变量模板
# 用法：复制为 env.sh，填入实际值后 source env.sh 再启动 LiteLLM
# 注意：切勿将填入实际值的文件提交到 git

# ============================================================
# LiteLLM 核心
# ============================================================
export LITELLM_MASTER_KEY="sk-change-me-master-key"
export DATABASE_URL="postgresql://litellm:password@localhost:5432/litellm"

# ============================================================
# Redis（路由状态共享）
# ============================================================
export REDIS_HOST="localhost"
export REDIS_PORT="6379"
export REDIS_PASSWORD=""

# ============================================================
# Azure Claude 订阅端点（SUB01–SUB10）
# 值来自 deploy-models.sh 输出的 foundry-endpoints.csv
# ============================================================
export AZURE_CLAUDE_SUB01_ENDPOINT="https://fdry-xxx-claude-xxxx.cognitiveservices.azure.com/"
export AZURE_CLAUDE_SUB01_KEY=""
export AZURE_CLAUDE_SUB02_ENDPOINT="https://fdry-xxx-claude-xxxx.cognitiveservices.azure.com/"
export AZURE_CLAUDE_SUB02_KEY=""
export AZURE_CLAUDE_SUB03_ENDPOINT="https://fdry-xxx-claude-xxxx.cognitiveservices.azure.com/"
export AZURE_CLAUDE_SUB03_KEY=""
export AZURE_CLAUDE_SUB04_ENDPOINT="https://fdry-xxx-claude-xxxx.cognitiveservices.azure.com/"
export AZURE_CLAUDE_SUB04_KEY=""
export AZURE_CLAUDE_SUB05_ENDPOINT="https://fdry-xxx-claude-xxxx.cognitiveservices.azure.com/"
export AZURE_CLAUDE_SUB05_KEY=""
export AZURE_CLAUDE_SUB06_ENDPOINT="https://fdry-xxx-claude-xxxx.cognitiveservices.azure.com/"
export AZURE_CLAUDE_SUB06_KEY=""
export AZURE_CLAUDE_SUB07_ENDPOINT="https://fdry-xxx-claude-xxxx.cognitiveservices.azure.com/"
export AZURE_CLAUDE_SUB07_KEY=""
export AZURE_CLAUDE_SUB08_ENDPOINT="https://fdry-xxx-claude-xxxx.cognitiveservices.azure.com/"
export AZURE_CLAUDE_SUB08_KEY=""
export AZURE_CLAUDE_SUB09_ENDPOINT="https://fdry-xxx-claude-xxxx.cognitiveservices.azure.com/"
export AZURE_CLAUDE_SUB09_KEY=""
export AZURE_CLAUDE_SUB10_ENDPOINT="https://fdry-xxx-claude-xxxx.cognitiveservices.azure.com/"
export AZURE_CLAUDE_SUB10_KEY=""

# ============================================================
# Azure GPT 订阅端点（SUB01–SUB05）
# ============================================================
export AZURE_GPT_SUB01_ENDPOINT="https://fdry-xxx-gpt-xxxx.cognitiveservices.azure.com/"
export AZURE_GPT_SUB01_KEY=""
export AZURE_GPT_SUB02_ENDPOINT="https://fdry-xxx-gpt-xxxx.cognitiveservices.azure.com/"
export AZURE_GPT_SUB02_KEY=""
export AZURE_GPT_SUB03_ENDPOINT="https://fdry-xxx-gpt-xxxx.cognitiveservices.azure.com/"
export AZURE_GPT_SUB03_KEY=""
export AZURE_GPT_SUB04_ENDPOINT="https://fdry-xxx-gpt-xxxx.cognitiveservices.azure.com/"
export AZURE_GPT_SUB04_KEY=""
export AZURE_GPT_SUB05_ENDPOINT="https://fdry-xxx-gpt-xxxx.cognitiveservices.azure.com/"
export AZURE_GPT_SUB05_KEY=""

# ============================================================
# Azure DeepSeek 订阅端点
# ============================================================
export AZURE_DS_SUB01_ENDPOINT="https://fdry-xxx-deepseek-xxxx.cognitiveservices.azure.com/"
export AZURE_DS_SUB01_KEY=""

# ============================================================
# Azure Batch GPT 订阅端点（定时任务池）
# ============================================================
export AZURE_BATCH_GPT_SUB01_ENDPOINT="https://fdry-xxx-gpt-xxxx.cognitiveservices.azure.com/"
export AZURE_BATCH_GPT_SUB01_KEY=""
export AZURE_BATCH_GPT_SUB02_ENDPOINT="https://fdry-xxx-gpt-xxxx.cognitiveservices.azure.com/"
export AZURE_BATCH_GPT_SUB02_KEY=""

# ============================================================
# Google Vertex AI（跨云 Claude 备份）
# ============================================================
export VERTEX_PROJECT_ID="your-gcp-project-id"
export VERTEX_LOCATION="us-east5"
export VERTEX_CREDENTIALS_JSON="/path/to/service-account.json"

# ============================================================
# 可观测性
# ============================================================
export LANGFUSE_HOST="https://langfuse.your-domain.com"
export LANGFUSE_PUBLIC_KEY=""
export LANGFUSE_SECRET_KEY=""
export OTEL_ENDPOINT="http://otel-collector:4317"
export SENTRY_DSN=""

# ============================================================
# Azure Sentinel 日志
# ============================================================
export AZURE_SENTINEL_WORKSPACE_ID=""
export AZURE_SENTINEL_SHARED_KEY=""

# ============================================================
# 告警
# ============================================================
export SLACK_WEBHOOK_URL="https://hooks.slack.com/services/xxx/yyy/zzz"
