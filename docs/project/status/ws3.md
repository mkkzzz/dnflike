# ws3 状态

> 只由 ws3 修改。开工、收工或切换任务时更新，最近完成保留 5 条。

| 字段 | 内容 |
|---|---|
| 使用者 | 开发者A |
| 状态 | 搁置 |
| 正在做 | — |
| 产出位置 | `docs/tasks/art_tasks/upper_lean_windup_rev2.md`（`on_hold`）、`art/sheets/v3/upper_lean_windup_rev2/generation.json` |

## 最近完成

- 2026-10-15 上挑专属升腾刃特效实装（`game/scripts/battle_fx.gd`，271 项回归通过）
- 2026-10-15 上挑起手深蹲体态问题定位：逐帧实测身高 + 排除代码原因，立项为美术 revision
- 2026-10-15 本区接入：登记 ws3 为 `D:/dnflike`、初始化 `.workspace`、本机环境记录
- 2026-10-15 本机安装目录迁出仓库（`_tools/`、`_dl/` → `D:/dnflike_local/`），修复 `check_docs.py` 假断链
- 2026-10-14 承接 ws2 转交的上挑表现层工作

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
