# ws1 状态

> 只由 ws1 修改。开工、收工或切换任务时更新，最近完成保留 5 条。

| 字段 | 内容 |
|---|---|
| 使用者 | rainmk |
| 状态 | 等用户试玩 |
| 正在做 | 用户首轮试玩 9 项返修已完成，等第二轮试玩（[战斗内核实装](../../design/29_新版工程框架_战斗内核实装.md) 五之二）；combat_runtime 已发 v10（G26）；下一步替换[还原缺口](../../tasks/design_tasks/ws1_combat_fidelity_gaps_v1.md) G05~G08/G17~G25 |
| 产出位置 | `game_dnf/core/`、`game_dnf/content/api/`、`game_dnf/combat/`（action/hit/resolve/ai/data/api/fields）、`game_dnf/data/combat.json`、`game_dnf/view/`、`game_dnf/ui/combat/`、`game_dnf/debug/`、`tools/dnf_pvf.py`、`tools/compile_dnf_content.py`、`tools/build_dnf_combat_assets.py`、`tools/ensure_dnf_combat.ps1`、`tools/check_dnf_deps.py`、`tools/trace_dnf.ps1` |

## 最近完成

- 2026-10-23 经用户授权发布循环锁 dnf-loop-v10-ws1-combat-lorien-20261023（只换 combat_runtime，含洛兰地图导出），干净目录实跑循环 315、战斗 143 项通过
- 2026-10-23 用户试玩 9 项返修：ANI 旋转（击飞怪物不再下坠）、上挑换 hitback.ani+upperslash 特效+UPPER_SLASH_01、跳斩空中移动、突刺仅奔跑中、三段斩按 SKL static_data 平滑滑行+分段转向、↓+C 后跳打断普攻并留虚影、十字斩新月归位与斩痕随招式清除、五房换原版洛兰地图（通行格/镜头/门/怪物表/起点）、屏幕上方原版 monster_hp.img 血条。战斗 143、循环 315、地图 88 项通过
- 2026-10-22 29 框架 F3~F5 战斗内核：ANI 时间线 + 攻防盒相交判定、ATK 受击反应/击退/浮空/倒地、局部停帧、SKL 1 级蓝耗/冷却/伤害%、原版命中特效与命中音（ATK/CHR 武器行）、ANI 帧音效、combo.img 位图跳字与连击、MOB 驱动的原版哥布林（Animation_Goblin2）与投掷手（石块飞出物）；招式改为上挑/拔刀斩/三段斩/十字斩/暴走；删除自制染红与每击震屏。战斗 121、循环 92、地图 88 项通过；运行时执行原版字段 ATK 56%/CHR 82%/SKL 17%/MOB 16%
- 2026-10-22 29 框架 F2 原版内容编译：通用 PVF 解析库、编译器输出鬼剑士+哥布林系原版记录（缺失引用 0）与全库字段覆盖报告；ContentDB 按原版路径查询
- 2026-10-22 循环接入新战斗框架（用户要求 ws1 自做）：loop_root 改经 combat_session，删除 legacy_combat_port；角色属性经 start_room 传入
- 2026-10-22 29 框架 F1 表现拆分：表现移出 main.gd，改为只读快照 + combat.* 事件驱动；HUD 拆成自动发现控件；无窗口表现轨迹验证逐帧一致
