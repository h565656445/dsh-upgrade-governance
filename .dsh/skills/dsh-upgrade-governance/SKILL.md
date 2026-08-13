---
name: dsh-upgrade-governance
description: 升级清单核验、凭据暴露扫描与升级审计技能 / Skill for upgrade checklist verification, credential-exposure scans, and upgrade audits
---

# Hermes 升级治理 / Hermes Upgrade Governance

本技能用于升级治理：核对升级清单、扫描凭据暴露、执行人工审批门并写升级审计投影。

This skill covers upgrade governance: verifying the upgrade checklist, scanning for credential exposure, enforcing manual-approval gates, and writing upgrade audit projections.

## When to use / 何时使用

需要升级前核验清单、扫描凭据暴露或产出升级审计时。

Use when verifying upgrade checklists, scanning for credential exposure, or producing upgrade audits.

## Workflow / 工作流

1. 读取升级清单（upgate_checklist.json）。
2. 执行凭据暴露扫描（G1 等检查）。
3. 过人工审批门。
4. 写升级审计投影并核对。

## References / 参考

- 项目 README: 见仓库根目录
- 作者: h565656445 (GitHub)