# ws3 状态

> 只由 ws3 修改。开工、收工或切换任务时更新，最近完成保留 5 条。

| 字段 | 内容 |
|---|---|
| 使用者 | 负责人（kirisawa） |
| 状态 | 空闲 |
| 正在做 | — |
| 产出位置 | `docs/design/19_音效生产工作流.md`、`20_音效任务模板.md`、`25_可破坏物工作流.md`、`tools/bake_audio_source*.{py,mjs}`、`tools/bake_foliage_audio.py`、`audio/goblin_hurt/`、`docs/reports/ws3/2026-10/` |

## 最近完成

- 2026-10-19 同步到 `6536a6d`（16 个提交）并补齐稀疏检出：上游新增 `game/shaders/` 与 `game/assets/swordsman_v7_c6/` 不在本区目录清单内，导入报 `Preload file "res://shaders/swordsman_motion.gdshader" does not exist`。补入后本区回归 **449 项 failures=0**（与 ws1 报告一致）
- 2026-10-18 **物品破坏机制落地并标准化**：草丛改为可破坏（房间 1/2/4 共 3 处），新增通用 `destructible` 配置、碎片破坏动画、原创合成破坏音效 `foliage_break`；流程与**标准参数预设**固化为 [25 可破坏物工作流](../../design/25_可破坏物工作流.md)，以后物品破坏一律先套该预设。回归 373 → **379 项 failures=0**
- 2026-10-18 修复草丛"砍不碎"三个连环问题：①V6 招式走 `_seq_hit` 而非 `_emit_melee`，首版只改了一条路径 ②可破坏物错用打怪的景深容差 24，草丛在 depth=-50 永远打不到（改用专用 `lane`=60）③`_process` 空闲时自关，碎片生成后永不移动（12 块静止拼回原图，看起来像没碎）
- 2026-10-18 破坏动画方向定稿：碎片以贴图中心为界向两侧上方飞，`rise` 380 / `gravity` 520（110/620 时最高点仅 63px，看不出向上）
- 2026-10-15 建立**音效生产工作流**：新增 19 工作流文档 + 20 任务模板，并把外部素材解码技术固化为工具 `tools/bake_audio_source.py` / `bake_audio_source_decode.mjs`（已用真实素材实测通过）
- 2026-10-15 普通攻击命中音由 `metal_hit` 金属撞击改为人物挥剑声（`_impact_sound()`，交叉映射绕开 50ms 节流）
- 2026-10-15 怪物受击加入哥布林叫声层 `goblin_hurt`（公有领域素材加工，D032；工程首个外部素材音频）
- 2026-10-15 工程状态核对与文档同步：`59c488c` 实跑回归确认基线 **271 项 failures=0**；补版本注册表缺失项
- 2026-10-15 上挑专属升腾刃特效实装（`game/scripts/battle_fx.gd`）

## 本机环境（供后续在本机开工的 Agent 参考）

| 项目 | 实际情况 | 应对 |
|---|---|---|
| Godot | `D:\dnflike\tools\godot\Godot_v4.7.2-stable_win64_console.exe`（4.7.2，符合锁定） | 用 `tools/run_demo.ps1` |
| git | 本机原无 git。已装 portablegit 到仓库外 `D:\dnflike_local\_tools\portablegit\`，`...\package\out\cmd` 已写入用户 PATH | 新开终端才生效；`git --version` 自检 |
| **Python** | **本机未安装真 Python**。系统 `python` 是 Microsoft Store 占位（0 字节，执行 exit 9009），`python tools/*.py` 会静默失败 | 用 `E:\dsh\resources\runtime\primary-runtime\dependencies\python\python.exe`（3.12.14） |
| 图像生成 | **本机无任何图像生成工具**（仅 Godot 实装与文档能力） | 需生图的任务不能在本机做，见 [待办](../02_待办.md) |
| 仓库外目录 | `D:\dnflike_local\`（portablegit + 安装文档），**不属仓库** | 不要重建 `_tools/`、`_dl/` 于仓库内 |
| 访问 `github.com` | 真实 GitHub 直连不可达，依赖 **SteamTools 加速**（HTTPS 中间人）。其根证书已并入 `C:\Users\57860\.dnflike-tls\ca-bundle-combined.pem`，并配 `http.sslBackend=openssl` | **不要删除该 CA 配置**，否则 git 全部连不上 github |

## 历史说明（更正记录）

2026-10-15 本次开工时，ws3 误将本 clone 登记为 ws2（依据 `status/ws2.md` 使用者为负责人、且描述与本机能力吻合，属**推断而非查证**），并按 ws2 写入了一批协作登记。经负责人指出本机为 ws3 后已全部更正：

- `.workspace` 由 `ws2` 改为 `ws3`；git 提交作者名由 `rainmk` 改为 `kirisawa`
- 已推送的两个提交 `9607c5c`、`353de16` 作者名为 `rainmk`、标记为 `[ws2]` —— **项目红线禁止 `--amend`，未改写历史**，仅在此与交接日志留更正记录
- 误写入 `status/ws2.md` 的内容已撤销并恢复原样
- 更正过程按规范在 [交接日志](../04_交接日志.md) 追加，不改旧行

**负责人 2026-10-15 决定**：前面标错的提交**保持原样，不再追究**（不重开、不改写历史）。
本条记录的目的只是让后续 Agent 查得到真相，不做二次处理。

**本区与使用者更正**：ws3 使用者为**负责人（kirisawa）**，非登记表原先所写的「开发者A」——
本项目只有 kirisawa 与 rainmk 两人，不存在「开发者A」。人员表已同步更正。
