# ws2 状态

> 只由 ws2 修改。开工、收工或切换任务时更新，最近完成保留 5 条。

| 字段 | 内容 |
|---|---|
| 使用者 | 负责人 |
| 状态 | 搁置 |
| 正在做 | — |
| 产出位置 | `docs/tasks/art_tasks/upper_lean_windup_rev2.md`（上挑起手 revision 任务单，`on_hold`）；`art/sheets/v3/upper_lean_windup_rev2/generation.json`（两版提示词） |

## 最近完成

- 2026-10-15 上挑专属升腾刃特效实装（`battle_fx.gd`，271 项回归通过）
- 2026-10-15 上挑起手深蹲体态问题定位（逐帧实测 + 排除代码原因）并立项
- 2026-10-15 跳跃空中机动对齐原版 DNF
- 2026-10-14 五项手感优化（跑步持剑、纵深步态、每跳单次空斩、攻击衔接后跳）
- 2026-10-14 V6 四招实装与对位修复

## 本机环境（供后续在本机开工的 Agent 参考）

| 项目 | 实际情况 | 应对 |
|---|---|---|
| Godot | `D:\dnflike\tools\godot\Godot_v4.7.2-stable_win64_console.exe`（4.7.2，符合锁定） | 用 `tools/run_demo.ps1` |
| git | 本机原无 git。已装 portablegit 到 `D:\dnflike_local\_tools\portablegit\`，并把 `...\package\out\cmd` 写入用户 PATH | 新开终端才生效；`git --version` 自检 |
| **Python** | **本机未安装真 Python**。系统 `python` 是 Microsoft Store 占位（0 字节，执行 exit 9009），所以 `python tools/*.py` 会静默失败 | 用 DSH 自带：`E:\dsh\resources\runtime\primary-runtime\dependencies\python\python.exe`（3.12.14） |
| 图像生成 | **本机无任何图像生成工具**（仅 Godot 实装与文档能力） | 需生图的任务不能在本机做，见 [待办](../02_待办.md) |
| 仓库外目录 | `D:\dnflike_local\`（portablegit + 安装文档），**不属仓库** | 不要重建 `_tools/`、`_dl/` 于仓库内 |
| 从 `github.com` 访问 | 真实 GitHub 在直连下不可达，依赖 **SteamTools 加速**（HTTPS 中间人）。已把其根证书并入 `C:\Users\57860\.dnflike-tls\ca-bundle-combined.pem` 并配 `http.sslBackend=openssl` | **不要删除该 CA 配置**，否则 git 全部连不上 github |
