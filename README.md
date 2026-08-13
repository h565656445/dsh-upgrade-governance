# dsh-upgrade-governance

<!-- DeepSeek Harness 衍生声明 -->
> **DeepSeek Harness 个人适配声明（Personal Adaptation Notice）**
>
> 本项目是 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的**个人适配产物（personal adaptation）**，**并非 DeepSeek Harness 官方文件（not an official DeepSeek Harness file）**，随附功能、使用说明与个人产物（bundled with features, documentation, and personal artifacts），可与 DeepSeek Harness 搭配使用，也可独立使用。
>
> This project is a **personal adaptation** for DeepSeek Harness, and is **NOT an official DeepSeek Harness file**, bundled with features, documentation, and personal artifacts. It can be used alongside DeepSeek Harness or standalone.

**作者 / Author**: [h565656445](https://github.com/h565656445)

**合作 / Collaboration**: 如有项目可以一起合作，欢迎联系。微信：`wohaishihenshuaide`。If you have projects, let's collaborate. WeChat: `wohaishihenshuaide`.


---

## 用途 / What this is for

升级治理模块：适配器升级清单与审计，约束升级路径与清单校验。

Upgrade governance module: adapter upgrade checklists and audit.

---
## Hermes Upgrade Governance / Hermes 升级治理

升级治理与安全门禁：`HermesUpgradeGovernance.psm1` 对升级清单（`config/upgate_checklist.json`，保留源文件名）执行凭据暴露扫描、人工审批门（G 系列治理检查）并写升级审计投影（`upgrade-audit` schema v0.2）；`HermesAdapterUpgrade.Tests.ps1` 覆盖适配器升级回归。

Upgrade governance and security gates: `HermesUpgradeGovernance.psm1` runs credential-exposure scans over the upgrade checklist (`config/upgate_checklist.json`, source filename kept), enforces manual-approval gates (G-series governance checks), and writes upgrade audit projections (`upgrade-audit` schema v0.2); `HermesAdapterUpgrade.Tests.ps1` covers adapter upgrade regressions.

## Features / 功能

- 凭据暴露扫描：对活动 v0.2 工件与安全日志扫描凭据类值 / Credential-exposure scan over active v0.2 artifacts and security logs
- 人工审批门：`Test-HermesManualApprovalGate` 把关升级/记录操作 / Manual approval gate for upgrade actions
- 升级审计：`Invoke-HermesUpgradeAudit` 写只读审计投影 / Upgrade audit projection
- 命名治理检查：如 `G1_CREDENTIAL_EXPOSURE` / Named governance checks (e.g. G1_CREDENTIAL_EXPOSURE)
- 回归测试：`HermesAdapterUpgrade.Tests.ps1` / Adapter upgrade regression suite

## What's inside / 目录结构

```
dsh-upgrade-governance/
├── README.md
├── LICENSE
├── src/HermesUpgradeGovernance.psm1
├── config/upgate_checklist.json        # 源文件名保留
├── schemas/schema_registry/v0.2/
│   ├── upgrade-audit.schema.json
│   └── upgrade-checklist.schema.json
├── tests/HermesAdapterUpgrade.Tests.ps1
└── .dsh/
```

## Quick start / 快速开始

```powershell
Import-Module .\src\HermesUpgradeGovernance.psm1 -Force

# 执行升级审计
Invoke-HermesUpgradeGovernance -Action Audit -Root . `
  -ChecklistPath .\config\upgate_checklist.json

# 运行回归测试
pwsh -NoProfile -Command "Invoke-Pester -Path .\tests"
```

## DeepSeek Harness 衍生 / DSH Derivative

本项目附带 DeepSeek Harness 衍生包，位于 `.dsh/` 目录：

- `preset.yml` — Agent 预设元数据
- `agent.cordis.yml` — Cordis 组装（基于 standard 预设，persona 已定制）
- `skills/dsh-upgrade-governance/SKILL.md` — 项目专属技能（skill）

安装与接入方式见 [`.dsh/README.md`](.dsh/README.md)（双语）。

## License / 许可证

[MIT](LICENSE)

---

## 相关项目 / Related Projects

> 这是 DeepSeek Harness 个人适配系列（共 40 个仓库）的完整导航。 / This is the complete navigation for the DeepSeek Harness personal-adaptation series (40 repos).

### Agent OS 内核 / Kernel

[`dsh-agent-os-runtime`](https://github.com/h565656445/dsh-agent-os-runtime) · [`dsh-agent-os-planning`](https://github.com/h565656445/dsh-agent-os-planning) · [`dsh-agent-os-scheduler`](https://github.com/h565656445/dsh-agent-os-scheduler) · [`dsh-agent-os-worker-protocol`](https://github.com/h565656445/dsh-agent-os-worker-protocol) · [`dsh-agent-os-observability`](https://github.com/h565656445/dsh-agent-os-observability) · [`dsh-agent-os-specs`](https://github.com/h565656445/dsh-agent-os-specs)

### Harness 基础设施 / Infrastructure

[`dsh-harness-core`](https://github.com/h565656445/dsh-harness-core) · [`dsh-graph-entry`](https://github.com/h565656445/dsh-graph-entry) · [`dsh-async-job`](https://github.com/h565656445/dsh-async-job) · [`dsh-file-identity`](https://github.com/h565656445/dsh-file-identity) · [`dsh-json-projection`](https://github.com/h565656445/dsh-json-projection) · [`dsh-manual-approval`](https://github.com/h565656445/dsh-manual-approval) · [`dsh-observation-writer`](https://github.com/h565656445/dsh-observation-writer) · [`dsh-provider-control`](https://github.com/h565656445/dsh-provider-control) · [`dsh-schema-negotiator`](https://github.com/h565656445/dsh-schema-negotiator) · [`dsh-schema-registry`](https://github.com/h565656445/dsh-schema-registry) · **`dsh-upgrade-governance`（本仓库 / this repo）** · [`dsh-task-contract`](https://github.com/h565656445/dsh-task-contract) · [`dsh-quality-gates`](https://github.com/h565656445/dsh-quality-gates) · [`dsh-worker-tests`](https://github.com/h565656445/dsh-worker-tests)

### Worker 与管线 / Workers & Pipelines

[`dsh-codex-worker`](https://github.com/h565656445/dsh-codex-worker) · [`dsh-novel-chapter-trial`](https://github.com/h565656445/dsh-novel-chapter-trial) · [`dsh-novel-video-pipeline`](https://github.com/h565656445/dsh-novel-video-pipeline) · [`dsh-portfolio-routing`](https://github.com/h565656445/dsh-portfolio-routing) · [`dsh-meta-agents-bridge`](https://github.com/h565656445/dsh-meta-agents-bridge)

### 规格与文档 / Specs & Docs

[`dsh-harness-specs`](https://github.com/h565656445/dsh-harness-specs) · [`dsh-novel-specs`](https://github.com/h565656445/dsh-novel-specs) · [`dsh-architecture-guide`](https://github.com/h565656445/dsh-architecture-guide) · [`dsh-powershell-patterns`](https://github.com/h565656445/dsh-powershell-patterns) · [`dsh-json-schema-driven-dev`](https://github.com/h565656445/dsh-json-schema-driven-dev) · [`dsh-llm-agent-harness-guide`](https://github.com/h565656445/dsh-llm-agent-harness-guide)

### 适配器 / Adapters

[`dsh-short-story-engine`](https://github.com/h565656445/dsh-short-story-engine) · [`dsh-tutorial-video-state-machine`](https://github.com/h565656445/dsh-tutorial-video-state-machine) · [`dsh-governance-kernel`](https://github.com/h565656445/dsh-governance-kernel) · [`dsh-sports-pipeline`](https://github.com/h565656445/dsh-sports-pipeline) · [`dsh-motion-grammar`](https://github.com/h565656445/dsh-motion-grammar)

### DSH 总集成 / Integration

[`dsh-integration`](https://github.com/h565656445/dsh-integration) · [`dsh-presets-pack`](https://github.com/h565656445/dsh-presets-pack) · [`dsh-skills-pack`](https://github.com/h565656445/dsh-skills-pack) · [`dsh-starter-kit`](https://github.com/h565656445/dsh-starter-kit)

