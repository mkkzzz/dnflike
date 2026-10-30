# ws1 状态

> 只由 ws1 修改。开工、收工或切换任务时更新，最近完成保留 5 条。

| 字段 | 内容 |
|---|---|
| 使用者 | rainmk |
| 状态 | 已发布 |
| 正在做 | 2026-10-30 [普通哥布林多招式停靠回归修复](../../reports/ws1/2026-10/2026-10-30_普通哥布林多招式停靠回归修复.md)已发布，独立战斗 **143项 failures=0**；等待 ws2 保留原断言接收复核。标准 `run_dnf.ps1 -Test` 仍被17条既有 content 依赖门禁挡在战斗前，另列待办 |
| 产出位置 | `game_dnf/core/`、`game_dnf/content/api/`、`game_dnf/combat/`（action/hit/resolve/ai/data/api/fields）、`game_dnf/data/combat.json`、`game_dnf/view/`、`game_dnf/ui/combat/`、`game_dnf/debug/`、`tools/dnf_pvf.py`、`tools/compile_dnf_content.py`、`tools/build_dnf_combat_assets.py`、`tools/ensure_dnf_combat.ps1`、`tools/check_dnf_deps.py`、`tools/trace_dnf.ps1` |

## 最近完成

- 2026-10-30 修复[普通哥布林多招式停靠回归](../../reports/ws1/2026-10/2026-10-30_普通哥布林多招式停靠回归修复.md)：选招与靠近统一攻击距离带、消除停靠死区、过滤空攻击段；独立战斗 **143项 failures=0**，待 ws2 接收复核。

- 2026-10-30 完成[Codex 技能与 Godot 后台 MCP](../../reports/ws1/2026-10/2026-10-30_Codex技能与Godot后台MCP接入.md)：三个项目 skill、固定版 MCP、本机配置与隐藏桌面隔离；技术验证通过，战斗场景现存标签/贴图加载错误另列，未计完整回归或用户验收。

- 2026-10-30 发布[副本 BOSS 的 AI 数据边界](../../design/48_副本BOSS的AI数据边界.md)（`f2eda3e8`）：纠正 AI 按族共享的查找层级，并区分脚本存在与实质选招逻辑；不把旧版[47 架构说明](../../design/47_怪物复刻完成度与架构边界.md)中的早期结论当作完成验收。
- 2026-10-30 提交时序敏感用例的轮询等待及拾取下蹲窗口调整（`fee1c129`）；本轮接续只核对提交和差异，未复跑游戏回归。
- 2026-10-29 提交新版怪物动作自动反推及版本切换工具（`1c4d8f56`），入口 `tools/build_dnf_monster_catalog.py`、`tools/switch_monster_version.py`；新版与旧版共用美术的对照更正见[47 补充实测](../../design/47_怪物复刻完成度与架构边界.md#七补充实测新版与老版外观完全相同)。

## 接续时的未完成工作

- `7a00f659` 已提交族级 AI 目录索引、运行时回退查询和拾取下蹲帧计数；接续时“未提交”的记载已纠正，未将提交视作回归或试玩通过。
- [ws2 多招式接收诊断](../../reports/ws2/2026-10/2026-10-29_ws1多招式接收回归差异.md)：ws1 已完成修复并从独立场景复跑通过；等待 ws2 在当前主线保留原断言接收复核。
- `tools/run_dnf.ps1 -Test` 当前仍被 17 条既有 `content/` 模块直连违规挡在战斗前；直接独立场景回归已通过，不能把后者写成标准入口通过。
