# DNF 原生像素新版验证工程

独立 Godot 项目，使用现有本地 DNF IMG/ANI 资源实现战斗与五房副本样板。
玩法范围对照旧工程；原生像素、动作时序、锚点和分层按本套资源建立。
首轮实机视频演示已获用户验收；后续新增内容仍按具体范围验收。

原版还原与跨区设计共用入口：[拆解与还原路线](../docs/design/26_DNF原版拆解与还原路线.md)。现版适配差异、证据规范和五类品质对照从此进入。

引擎沿用仓库固定 Godot 4.7.2。旧工程入口保持在 `game/`。

```powershell
# 仓库根目录：启动游戏
tools/run_dnf.ps1
# 城镇→五房战斗→结算回城/背包/任务/存档（独立入口）
tools/run_dnf_loop.ps1
# 同入口鼠标/战斗/存档检查，保存实际画面
tools/run_dnf_loop.ps1 -Test -Capture
# 打开新版编辑器
tools/run_dnf.ps1 -Editor
# 自动化战斗/副本验证；-Capture 额外保存实际渲染帧到 temp/
tools/run_dnf.ps1 -Test -Capture
# 原地图导出与独立验证场景（T2，需完整库）
tools/run_dnf_map.ps1 -Test
```

循环入口固定1920×1080输出，F11切换全屏/窗口；F3不再更改分辨率。
编辑器Game预览的启动尺寸也为1920×1080；更新后停止旧进程再运行，若保留旧项目设置则先重新加载工程。嵌入预览的缩放/窗口由编辑器工具栏管理，F11仅用于独立窗口。
原版800×600内容以4:3居中，两侧留边；纹理最近邻采样，字体按1.8倍显示密度重栅格化，不拉宽角色或UI。
编辑器打开scenes/loop.tscn按F6。P打开/关闭GM面板，输入时P为文字，Esc关闭；[命令与调试说明](../docs/reports/ws2/2026-10/2026-10-22_固定1080p与GM调试面板.md)。

## 共享资源

完整资源存放在工程外，通过独立资源仓库的版本包共享。
启动时缺少资源或资源版本变化会自动同步小型运行包；完整库不用复制进每个 Godot 项目。
`asset_store.json` 固定包版本与 SHA256；`assets_local/` 只是被 Git 忽略的消费副本。

```powershell
# 各工作区拉取运行包，随后用 tools/run_dnf.ps1 启动
python tools/dnf_asset_store.py sync
# 需要选资源、查动作时，拉取完整库到工程外；同机各 clone 共用一份
python tools/dnf_asset_store.py sync --full
# 查看完整分类库、动作帧和配置（需Pillow）
python tools/browse_dnf_assets.py
```

Windows 默认缓存根为仓库所在盘的 `dnflike-assets`；可设 `DNFLIKE_ASSET_HOME`。
GitHub 凭据从现有 Git 登录或本机 `GH_TOKEN` 读取，凭据不写入仓库。
从外部完整库重建需 Pillow；已选源齐全时运行 `python tools/build_dnf_assets.py`。
来源、权限和完整同步步骤见[共享说明](../docs/design/23_DNF资源共享与工作区接入.md)。
循环用独立小包自动同步，不需原客户端或完整库；分工/临时战斗桥与未完成项见[循环实装记录](../docs/reports/ws2/2026-10/2026-10-22_原生素材城镇循环首轮实装.md)。

## 操作

方向键移动、同向双击奔跑；X 普攻/跑动攻击/空中攻击；C 或空格跳跃。
Z 上挑；A 拔刀斩；S 三段斩（连按续段）；D 十字斩；F 暴走；V 后跳；按住 G 格挡。
1/2/3 切换短剑/太刀/巨剑。战斗规则与原版对应见[战斗内核实装](../docs/design/29_新版工程框架_战斗内核实装.md)。
清怪后走入门口切房；领主房清完直接结算。R 在结算后重新挑战。
F1 操作说明、Esc 暂停、M 静音、F3 切换窗口尺寸；F2 显示碰撞辅助。

设计范围、来源差异和验收边界见
[任务包](../docs/tasks/art_tasks/dnf_native_v1.md)。
