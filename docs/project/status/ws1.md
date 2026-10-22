# ws1 状态

> 只由 ws1 修改。开工、收工或切换任务时更新，最近完成保留 5 条。

| 字段 | 内容 |
|---|---|
| 使用者 | rainmk |
| 状态 | 进行中 |
| 正在做 | 按[28分工](../../design/28_工作区分工与原版资料共享.md)承接战斗迭代；[29框架](../../design/29_新版工程框架.md) F0、F1 已完成，下一步 F2 原版内容编译（PVF token 解码库化，鬼剑士+哥布林 CHR/ANI/ATK/SKL/MOB，字段覆盖报告）。等 ws2 确认战斗入口接口 v1 |
| 产出位置 | `game_dnf/core/`、`game_dnf/content/api/`、`game_dnf/combat/api/`、`game_dnf/view/`、`game_dnf/ui/combat/`、`game_dnf/debug/`、`tools/check_dnf_deps.py`、`tools/trace_dnf.ps1`；[还原缺口](../../tasks/design_tasks/ws1_combat_fidelity_gaps_v1.md) |

## 最近完成

- 2026-10-22 29 框架 F1 表现拆分：角色/特效/物件视图、跳字、震屏、音频与 HUD 移出 main.gd，改为只读快照 + combat.* 事件驱动；HUD 拆成 8 个自动发现控件；无窗口表现轨迹工具验证拆分前后 770 帧逐帧一致；战斗 82、ws2 循环 64、T2 地图 88 项通过。用户要求不弹窗口，所有运行改为 headless
- 2026-10-22 29 框架 F0：core（事件总线/Box6/确定性随机）、ContentDB 三层叠加（基线/适配/超越，适配不得覆盖原版值）、CombatSession 外部管理模式与三个流程事件、TestAPI 门面、模块依赖检查接入 `run_dnf.ps1 -Test`；回归 79 项；登记 D034 与现存占位表现清单；接收补充参考包
- 2026-10-22 新版工程框架设计：五层单向依赖、模块目录与归属、命令/事件/快照/查询四种通信、并行开发规则、60版基线/适配/超越三层、F0~F5 渐进迁移；登记 D033（60版为最低目标、数据驱动）
- 2026-10-22 T2 原地图加载首轮：导出工具（原始 token/哈希/诊断）、加载器、验证场景；坐标/通行网格/门掩码按全库统计推断；验证场景 88 项、导出单测 6 项、主回归 59 项通过
- 2026-10-22 接收 DNF assets v1：私库读取、`sync --full`（全库 57100 文件逐包 SHA256 通过）、`audit_dnf_design.py`（336082 文件、样本 0 错误）、`run_dnf.ps1 -Test` 59 项 failures=0，跑后工作区干净
