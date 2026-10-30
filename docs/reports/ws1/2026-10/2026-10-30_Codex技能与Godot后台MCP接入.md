# Codex 技能与 Godot 后台 MCP 接入

## 交付

用户授权从 CodeBuddy 接续 ws1 并配置适合战斗开发的工具；追加要求：自动启动 Godot 不弹出窗口、不抢焦点。工作区身份与分工保持现行契约。

| 能力 | 入口 | 用途 |
|---|---|---|
| 战斗排查 skill | [dnf-combat-debug](../../../../.agents/skills/dnf-combat-debug/SKILL.md) | 输入、时钟、AI、攻防盒、命中、事件、表现排查与验证 |
| 原版数据审计 skill | [dnf-source-audit](../../../../.agents/skills/dnf-source-audit/SKILL.md) | 原版来源、字段、依赖、编译与运行功能覆盖核对 |
| 工作区接续 skill | [dnf-workspace-handoff](../../../../.agents/skills/dnf-workspace-handoff/SKILL.md) | 引用协作总纲执行开工/收工、身份与状态校对 |
| 隐藏桌面启动 | [start_dnf_mcp_background.py](../../../../tools/start_dnf_mcp_background.py) | 在私有 Windows 桌面运行 MCP 和 Godot，保持 stdio 通信 |
| 项目适配器 | [start_dnf_mcp.mjs](../../../../tools/start_dnf_mcp.mjs) | 固定 Godot MCP Runtime 3.8.1、本仓库工程及后台模式，停止后恢复格式变化 |

本机生效配置为 CODEX_HOME 下 config.toml，新增服务器名 `godot-dnf`。安装包位于本机 CODEX_HOME 的 mcp 子目录；机器路径只留本机配置，修改前备份在同目录 backups。其它项目的 Unreal、TAPD、Perforce、Rider 等连接原值保留。三个 skill 已被当前宿主发现；新增 MCP 在宿主重载服务器后可作为会话工具使用，保存配置不等于当前会话已经热加载。

## 为什么使用独立隐藏桌面

原 MCP 的 background 模式在桥接脚本 `_ready()` 才将窗口移出屏幕，启动瞬间仍可弹窗。工程显示初始化也会居中。屏幕外位置和 NO_FOCUS 的预启动尝试未通过 Win32 前台监测，因此最终以独立桌面隔离整个 Node/MCP/Godot 进程树，不切换用户的输入桌面。

Python 入口创建私有桌面，启动挂起的 Node 并加入 kill-on-close job 后恢复执行。进程树退出或启动器被终止时释放后台子进程。Node 适配器默认强制后台，GUI 启动能力不在本机工具清单中；规则回归继续用已有 headless 入口。

渲染仍使用实际 Godot 图形驱动，可通过 MCP 截图与注入输入；这不是渲染关闭的 headless 模式。临时桥接与截图落在工程 `.mcp`，由工程内 `.gitignore` 排除。最终方案不写 override.cfg。使用者自行试玩仍走正常入口。

## 验证快照

- skill-creator 的 quick_validate 对三个 skill 均通过；Python 编译、Node 语法检查通过。
- 实际 MCP 握手识别服务器 3.8.1，Godot 版本为 4.7.2.stable.official.ed1daf0bf。
- 当前战斗场景在隐藏桌面启动；读取到玩家状态、怪物数和模拟时钟，右方向输入将玩家 x 从 834.5 推进到 852.0，保存 1920×1080 截图。技术能力可用，不将该截图视为玩法验收。
- 最小临时场景验证：显式传 background:false 仍走隔离桌面；对象 x 从 100 推进到约 118.3，截图成功，日志无 SCRIPT ERROR/ERROR。测试场景与详细输出在本机临时目录，不作为正式游戏内容入库。
- 同步 Win32 监测：启动、输入、截图和停止期间 Godot 前台样本为 0，当前桌面内可见 Godot 窗口样本为 0。验证没有切换到私有桌面。
- 停止后无 Godot 残留进程；桥接 autoload 被清理，project.godot 与启动前字节相同；没有 override.cfg 遗留。

## 当前工程错误与验证边界

战斗场景检查基于本轮期间的 `441c13f6`，发现以下运行错误，属于当前工程数据/加载问题，未在工具配置任务中修改战斗实现或资源：

- `combat/api/combat_session.gd:35` 本地化标签默认值直接读 definition.name，部分怪物定义缺字段，触发 Dictionary 的 name 访问错误。
- `assets_local/combat/mob_goblin.png` 加载报无 loader，随后 actor_view 的纹理为空。需要在资源构建/导入链路确认实际源图与导入状态。

旧音频 Vorbis 标签另有编码/注释警告。本批未制作或加工音效。隐藏桌面最小场景测试通过不代表完整战斗回归通过；普通哥布林命中待办、场景观感和第二轮战斗试玩继续保持原待确认状态。

## 使用与后续维护

任务可直接调用 `$dnf-combat-debug`、`$dnf-source-audit` 或 `$dnf-workspace-handoff`，也允许正常自动选用。协作规则继续只引用总纲，skill 不复制另一份 Git 规则。

诊断顺序：check_project → run_project → 状态读取/输入/截图 → get_debug_output → stop_project。自绘 HUD 不一定产生 Control 节点，get_ui_elements 返回空时用节点状态与截图判断。后台进程可能因游戏自身失焦暂停，先读取 paused，再决定是否用输入恢复。

本机工具清单保留运行诊断、节点/依赖/设置读取、脚本校验与性能分析，排除直接打开编辑器和通用场景增删工具。MCP 包升级需重新核对内部适配接口并复跑背景/输入/截图/清理验证；当前安装固定 3.8.1。
