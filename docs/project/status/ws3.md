# ws3 状态

> 只由 ws3 修改。开工、收工或切换任务时更新，最近完成保留 5 条。

| 字段 | 内容 |
|---|---|
| 使用者 | 负责人（kirisawa） |
| 状态 | 空闲 |
| 正在做 | — |
| 产出位置 | `docs/design/19_音效生产工作流.md`、`20_音效任务模板.md`、`25_可破坏物工作流.md`、`tools/bake_audio_source*.{py,mjs}`、`tools/bake_foliage_audio.py`、`tools/bake_goblin_death*.py`、`tools/bake_skill_impacts.py`、`tools/bake_sword_swings.py`、`tools/bake_effort_voices.py`、`audio/{goblin_hurt,sword_swing,effort_voice}/`、`docs/reports/ws3/2026-10/` |

## 最近完成

- 2026-10-22 **把 ws2 新版工程 `game_dnf` 接到本机**：加入稀疏范围、按资源库 Release 安装 runtime 资产（61 文件，sha256 全通过），跑通 `game_dnf` 回归；启动窗口「格兰之森 · 新版战斗验证」。随后上游新增战斗模块，`game_dnf` 现在需要**完整库**编译的战斗资产，故后台分批下载 3.31 GB 的 11 个 library 包（分片续传，进行中）
- 2026-10-22 开工补齐两个必需稀疏目录：`game/assets/swordsman_v7_c8`（297 文件）与 `c10`（1417 文件）；不补则主回归挂 3 条（c8/c10 断言）。主工程回归 **527 项 failures=0**
- 2026-10-20 **招式音与出招人声改用真实 CC0 录音**：九个招式音（Swishes 暖气流 + StarNinjas 金属剑击）、四档起手人声（HaelDB 男声）。金属类被反馈"太刺太短"后，用**四级低通 5 kHz** + 降调加长修到质心 5~7.8 kHz。**人声仍未通过验收**（负责人要求重做，已记入待办）
- 2026-10-20 **技能命中声逐技能**：`impact_thrust/quick_draw/rage_slash/upper` 各 3 变体，映射在 `battle_fx.SKILL_IMPACT`，质心按气质排开（怒斩最沉 1780 Hz → 拔刀斩最锐 5350 Hz）
- 2026-10-20 小地图按门方向排版、未访问隐藏、清房后直连房间闪烁；血蓝每秒回 1%；上挑蓝耗 6 点且与技能共用固定点数结算
- 2026-10-19 同步到 `6536a6d`（16 个提交）并补齐稀疏检出：上游新增 `game/shaders/` 与 `game/assets/swordsman_v7_c6/` 不在本区目录清单内，补入后本区回归 **449 项 failures=0**
- 2026-10-18 **物品破坏机制落地并标准化**：草丛可破坏（房间 1/2/4 共 3 处）、通用 `destructible` 配置、碎片动画、`foliage_break` 音效；流程与**标准参数预设**固化为 [25 可破坏物工作流](../../design/25_可破坏物工作流.md)
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
| **`game_dnf` 的资源库** | 资源在**私有**仓库 `mkkzzz/dnflike-assets` 的 Release（tag `dnf-native-assets-v1-20261022`）。需 GitHub 令牌：从 `git credential fill`（host=github.com，账号 asakura-kirisawa）取出后设为 `GH_TOKEN` | `python tools/dnf_asset_store.py sync` 装 runtime（61 文件）；`--full` 才下 11 个 library 包（3.31 GB） |
| **`run_dnf.ps1` 的 python** | 脚本内部直接调用 `python`，本机解析到 Store 占位 → 报 `Module dependency check failed` | 运行前把真 Python 目录**前置到 PATH**：`$env:PATH="E:\dsh\...\dependencies\python;$env:PATH"` |
| **GitHub 大文件下载** | 直连被限速到 **~0.11 MB/s**（对照 Cloudflare 直连 0.9 MB/s，排除本机带宽）；一次性流式下载会在 ~4 MB 处被掐断 | 用 **2 MB 分片 Range 续传**（`D:\dnflike_local\dnf_fetch_library.py`），每块短连接避开切断点；跨域跳转必须去掉 `Authorization`，否则 S3 拒绝（官方工具用 `SafeRedirect`） |
| 7890 代理 | Clash（CordCCore）**会自行退出**，`ProxyEnable=1` 但端口不监听，导致 `10061 连接被拒` | 下载/拉取失败时先查 `Get-NetTCPConnection -LocalPort 7890 -State Listen` |

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
