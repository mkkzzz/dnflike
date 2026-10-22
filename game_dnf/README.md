# DNF 原生像素新版验证工程

独立 Godot 项目，使用现有本地 DNF IMG/ANI 资源实现战斗与五房副本样板。
玩法范围对照旧工程；原生像素、动作时序、锚点和分层按本套资源建立。
首轮仍是本地验证，完整观感、音量和手感待用户试玩。

引擎沿用仓库固定 Godot 4.7.2。旧工程入口保持在 `game/`。

```powershell
# 仓库根目录：启动游戏
tools/run_dnf.ps1
# 打开新版编辑器
tools/run_dnf.ps1 -Editor
# 自动化战斗/副本验证；-Capture 额外保存实际渲染帧到 temp/
tools/run_dnf.ps1 -Test -Capture
```

## 本地资源

`assets_local/` 包含选用原始 IMG、ANI 元数据、原始 Ogg、图集与来源/哈希。
该目录和 Godot 导入缓存均被 Git 忽略，不提交、不推送。
用户授权将所需资源复制到项目路径；未据此推断素材的再分发许可。

```powershell
# 初次准备：需 Pillow；路径指向已提取的本机资源库
python tools/build_dnf_assets.py --library "temp/dnf_unpack_probe/library_v1"
# 本地 sources/ 已齐备时，可脱离原客户端与临时资源库重新编译
python tools/build_dnf_assets.py
```

新 clone 不附带上述第三方素材；先按本机已有资源准备，再运行。
资源缺失时主场景给出提示；启动脚本会明确报缺资源。

## 操作

方向键移动、同向双击奔跑；X 普攻/跑动攻击/空中攻击；C 或空格跳跃。
Z 上挑；A/S 职业技能；V 后跳；按住 G 格挡。
Tab 切换剑魂/狂战士，1/2/3 切换短剑/太刀/巨剑。
清怪后走入门口切房；领主房清完直接结算。R 在结算后重新挑战。
F1 操作说明、Esc 暂停、M 静音、F3 切换窗口尺寸；F2 显示碰撞辅助。

设计范围、来源差异和验收边界见
[任务包](../docs/tasks/art_tasks/dnf_native_v1.md)。
