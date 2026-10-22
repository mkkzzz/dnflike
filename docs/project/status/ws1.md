# ws1 状态

> 只由 ws1 修改。开工、收工或切换任务时更新，最近完成保留 5 条。

| 字段 | 内容 |
|---|---|
| 使用者 | rainmk |
| 状态 | 进行中 |
| 正在做 | 按[28分工](../../design/28_工作区分工与原版资料共享.md)承接战斗迭代；[29框架](../../design/29_新版工程框架.md) F0~F2 已完成、循环已接入公开战斗入口；下一步 F3 战斗内核（ANI 时间线执行器 + 原版攻击盒判定替换手写窗口/距离） |
| 产出位置 | `game_dnf/core/`、`game_dnf/content/api/`、`game_dnf/combat/`、`game_dnf/view/`、`game_dnf/ui/combat/`、`game_dnf/debug/`、`tools/dnf_pvf.py`、`tools/compile_dnf_content.py`、`tools/check_dnf_deps.py`、`tools/trace_dnf.ps1`；[内容编译](../../design/29_新版工程框架_内容编译.md)、[还原缺口](../../tasks/design_tasks/ws1_combat_fidelity_gaps_v1.md) |

## 最近完成

- 2026-10-22 29 框架 F2 原版内容编译：通用 PVF 解析库（区段/枚举槽位/拼写别名）、编译器输出鬼剑士+哥布林系 669 条原版记录（缺失引用 0，重建哈希一致）与全库字段覆盖报告（ATK 99.8%/CHR 96%/SKL 89%/MOB 58% 结构解码，运行时执行 0）；ContentDB 按原版路径查询；单测 6 项、战斗 92、循环 74 项通过
- 2026-10-22 循环接入新战斗框架（用户要求 ws1 自做）：loop_root 改经 combat_session，删除 legacy_combat_port；角色属性经 start_room 传入，增 apply_effect/set_paused/read_view 字段；循环 64、战斗 87、地图 88 项通过
- 2026-10-22 29 框架 F1 表现拆分：角色/特效/物件视图、跳字、震屏、音频与 HUD 移出 main.gd，改为只读快照 + combat.* 事件驱动；HUD 拆成 8 个自动发现控件；无窗口表现轨迹验证拆分前后 770 帧逐帧一致。用户要求不弹窗口，所有运行改为 headless
- 2026-10-22 29 框架 F0：core、ContentDB 三层叠加、CombatSession 外部管理模式与流程事件、TestAPI 门面、模块依赖检查；登记 D034 与现存占位表现清单
- 2026-10-22 新版工程框架设计：五层单向依赖、模块目录与归属、四种通信、并行开发规则、60版基线/适配/超越三层、F0~F5 渐进迁移；登记 D033
