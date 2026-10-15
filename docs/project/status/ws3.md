# ws3 状态

> 只由 ws3 修改。开工、收工或切换任务时更新，最近完成保留 5 条。

| 字段 | 内容 |
|---|---|
| 使用者 | 负责人（kirisawa） |
| 状态 | 空闲 |
| 正在做 | — |
| 产出位置 | 见下「最近完成」；上挑 rev2 资料在 `art/sheets/v3/upper_lean_windup_rev2/` |

## 最近完成

- 2026-10-15 工程状态核对与文档同步：在 `59c488c` 实跑回归确认基线 **271 项 / failures=0**；补版本注册表缺失项（v6 依 D031 为现行版本、standard_v1 的 c2 面向修正、upper rev2 登记为并入 D031）
- 2026-10-15 记录 D030（选母版 c1）与 D031（全量动作重做路线）并同步看板/待办
- 2026-10-15 更正协作中枢：人员与工作区归属（删除不存在的「开发者A」）、本区身份 ws2→ws3
- 2026-10-15 上挑专属升腾刃特效实装（`game/scripts/battle_fx.gd`，271 项回归通过）
- 2026-10-15 上挑起手深蹲体态问题定位：逐帧实测身高 + 排除代码原因，立项为美术 revision

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
