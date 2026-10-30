# ws1 状态

> 只由 ws1 修改。开工、收工或切换任务时更新，最近完成保留 5 条。

| 字段 | 内容 |
|---|---|
| 使用者 | rainmk |
| 状态 | 等用户试玩 |
| 正在做 | 2026-10-30 已由 Codex 接续原 CodeBuddy 的 ws1 工作，沿用原工作区身份与分工。最近推进怪物原版数据、动作与 AI 边界核查（[48 边界](../../design/48_副本BOSS的AI数据边界.md)）；族级规则索引与拾取下蹲帧计数仍为本地未提交改动，待验证。优先待办是[普通哥布林命中回归](../../reports/ws2/2026-10/2026-10-29_ws1多招式接收回归差异.md)，尚未关闭；[场景基准](../../design/41_场景画面基准.md)及[战斗第二轮试玩](../../design/29_新版工程框架_战斗内核实装.md)继续等用户确认 |
| 产出位置 | `game_dnf/core/`、`game_dnf/content/api/`、`game_dnf/combat/`（action/hit/resolve/ai/data/api/fields）、`game_dnf/data/combat.json`、`game_dnf/view/`、`game_dnf/ui/combat/`、`game_dnf/debug/`、`tools/dnf_pvf.py`、`tools/compile_dnf_content.py`、`tools/build_dnf_combat_assets.py`、`tools/ensure_dnf_combat.ps1`、`tools/check_dnf_deps.py`、`tools/trace_dnf.ps1` |

## 最近完成

- 2026-10-30 发布[副本 BOSS 的 AI 数据边界](../../design/48_副本BOSS的AI数据边界.md)（`f2eda3e8`）：纠正 AI 按族共享的查找层级，并区分脚本存在与实质选招逻辑；不把旧版[47 架构说明](../../design/47_怪物复刻完成度与架构边界.md)中的早期结论当作完成验收。
- 2026-10-30 提交时序敏感用例的轮询等待及拾取下蹲窗口调整（`fee1c129`）；本轮接续只核对提交和差异，未复跑游戏回归。
- 2026-10-29 提交新版怪物动作自动反推及版本切换工具（`1c4d8f56`），入口 `tools/build_dnf_monster_catalog.py`、`tools/switch_monster_version.py`；新版与旧版共用美术的对照更正见[47 补充实测](../../design/47_怪物复刻完成度与架构边界.md#七补充实测新版与老版外观完全相同)。
- 2026-10-29 推进副本怪物注册与动作图集、原版数值表、多招式与逐招冷却、AI/ACT 反编译、召唤及死亡变身、破坏粒子与陷阱伤害；新增内容依赖顺序见[44 内容接入工作流](../../design/44_内容接入工作流.md)。上述代码提交不代替用户实机验收。
- 2026-10-28 发布[技能面板与加点拖拽](../../reports/ws1/2026-10/2026-10-28_技能面板与加点拖拽交付.md)、[场景画面基准与黑条修复](../../reports/ws1/2026-10/2026-10-28_场景画面基准与黑条修复.md)，并将运行资源改为随仓库分发；试玩与中文名校对继续见[待办](../02_待办.md)。

## 接续时的未完成工作

- `game_dnf/combat/data/move_table.gd`、`tools/build_dnf_boss_rules.py` 与 `game_dnf/data/boss_rules.json`：本地增加族目录索引及运行时回退查询，尚未提交或验证。
- `game_dnf/view/battle_view.gd`：本地将拾取下蹲改为帧计数，尚未提交或验证。
- [ws2 多招式接收诊断](../../reports/ws2/2026-10/2026-10-29_ws1多招式接收回归差异.md)：当前 AI 仍使用不同的攻击区间与停靠区间；接续未修复，等待项保留。
