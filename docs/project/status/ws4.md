# ws4 状态

> 只由 ws4 修改。开工、收工或切换任务时更新，最近完成保留 5 条。

| 字段 | 内容 |
|---|---|
| 使用者 | OY315 |
| 状态 | 进行中 |
| 正在做 | 城镇传送点光墙已按用户反馈改为循环播放、并固定压到人物之下；无窗口 loop **343 项 failures=0**。后续可做开关门时序、按方向选上下、以及 T1 内容台账下一批（65 条非日文未解析判定、4 张非标准 LST、105 组同路径多版本） |
| 产出位置 | `game_dnf/town/gate_light.gd`、`tools/bake_town_gate_light.py`、`tools/ledger_dnf_content.py`、`docs/reports/ws4/2026-10/` |

## 最近完成

- 2026-10-27 **城镇传送点开门光墙（循环 + 人物在上）**：29 帧改为循环播放；整组深度固定 `-1500`（地面/背景之上、任何角色之下），人物贴图始终压在光墙上方；无窗口 loop **343 项 failures=0**（新增 4 条断言）。详见[报告](../../reports/ws4/2026-10/2026-10-27_城镇传送点开门光墙.md)
- 2026-10-27 **城镇传送点开门光墙**：`world.portals()` 的每个可见传送点 + 副本入口各放一组原版 `gateup`/`gatedown`（29 帧 ×60ms，加色混合），帧由 `tools/bake_town_gate_light.py` 从共享库烘焙
- 2026-10-27 **开工基线**：本机三套回归 `run_demo` **527**、`run_dnf` **143**、`run_dnf_loop` **339** 项 failures=0（Godot 4.7.2，`verify.ps1`）。**注意**：`game_dnf/assets_local/` 不入库，新 clone 少了掉落贴图/音效时 loop 套件会挂 5 项（掉落原版精灵、金币翻转、光柱动画、拾取音效加载与实际播放）；先跑 `python tools/bake_loot_sprites.py`（需完整库）再测
- 2026-10-27 **T1 内容台账首份**：按 111 备份库建立 LST→文件的可达性台账。82 张 LST（40 路径 / 38 名称 / 4 非标准布局），路径索引 100,558 条解析 99.6%，未解析 395 条中 330 条属日文本地化索引；294 个地下城入口全部可追到 `.dgn`，`mirkwood.dgn` 的 SHA256 与 `game_dnf/data/dungeons.json` 一致；另给出 `.map`/`.equ`/`.qst` 等未被索引文件的候选计数。详见[报告](../../reports/ws4/2026-10/2026-10-27_内容台账与索引解析.md)

## 本机环境（供后续在本机开工的 Agent 参考）

| 项目 | 实际情况 | 应对 |
|---|---|---|
| Godot | `tools/godot/Godot_v4.7.2-stable_win64_console.exe`（4.7.2，符合锁定） | 用 `tools/run_dnf*.ps1` |
| Python | `python` 可用（Python 3.12） | 直接 `python tools/*.py` |
| 完整资源库 | `D:\dnflike-assets\dnf-native-assets-v1-20261022\library_v1`（336,082 文件） | `tools/dnf_pvf.py` 的 `open_library()` 默认就指向它 |
| 原版客户端 | **本机没有**（全盘无 `Script.pvf` 安装目录，库内只有 4 份副本） | T0 运行期加载证据仍只能由有客户端的机器（ws2）做 |
| 回归入口 | `D:\新建文件夹\工作区1\verify.ps1`（本机包装脚本，不入库） | 三套顺序跑，日志写 `verify.log` |
