# 幽暗回廊 · DNF-like

原创手绘风单机横版动作 RPG，Godot 4.7.2。当前交付可玩的**战斗 demo v2**：选择鬼剑士 / 狂战士 / 剑魂，突破三波哥布林围攻，进入胜负结算并重玩。

## 开始试玩

```powershell
# 本机已有 Godot 时直接运行
powershell -NoProfile -ExecutionPolicy Bypass -File tools/run_demo.ps1

# 新机器先安装引擎，再按上一步启动
powershell -NoProfile -ExecutionPolicy Bypass -File tools/setup_godot.ps1
```

也可以用 Godot 打开 `game/project.godot` 后按 F6/F5 运行主场景。自备引擎可向启动脚本传入 `-GodotPath "C:\path\godot.exe"`。正式 demo 的贴图已提交到 `game/assets/demo/`，首次拉取**无需安装 Python 或重新烘焙美术**；启动脚本会完成 Godot 导入。

## 操作

| 按键 | 动作 |
|---|---|
| ← / → | 行走；双击同方向奔跑 |
| Shift + ← / → | 按住奔跑 |
| ↑ / ↓ | 调整地面纵深，攻击需要对齐敌人所在纵深 |
| X | 三段连击，允许提前输入缓冲 |
| Z | 上挑；命中后按 C 起跳，空中 X 追击 |
| C / 空格 | 跳跃 |
| ↓ + C | 后跳，起手有短暂无敌 |
| V | 按住格挡，减伤 80% |
| A / S | 狂战士：血怒 / 怒斩；剑魂：拔刀斩 / 连突刺 |
| 1 / 2 | 生命 / 魔力药水，共享 5 秒冷却 |
| Esc / F1 | 暂停 / 操作说明 |
| R / T | 重玩 / 切换职业试玩 |

M1 双转职各提供两个代表技能，D/F/G/H 尚未开放。最后一波含攻击前摇更明显、血量更高的哥布林队长。

## 验证与美术重建

```powershell
# 46 项自动断言：连招、攻速、浮空、技能、受身、死亡、暂停、重玩和完整通关
powershell -NoProfile -ExecutionPolicy Bypass -File tools/run_demo.ps1 -Test

# 真实渲染截图：标题、场景、技能命中 → temp/demo/
powershell -NoProfile -ExecutionPolicy Bypass -File tools/run_demo.ps1 -Capture

# 同时在真实渲染器中跑回归并保存真实三波通关结算截图
powershell -NoProfile -ExecutionPolicy Bypass -File tools/run_demo.ps1 -Test -Capture

# 仅修改美术源时需要 Python 工具链
python -m pip install -r requirements.txt
python tools/bake_demo_art.py
python tools/bake_demo_art.py --validate-only
python tools/bake_demo_environment.py
```

回归测试会静音并验证合成 PCM 数据，普通试玩和单独截图模式保留音效。`-Test` 检查引擎错误、完成标记与退出码，失败会返回错误。

角色使用内置 imagegen 制作的两张透明 atlas：32 个核心姿势，25 个动作条、83 个输出帧。部分技能和过渡动作有限复用核心姿势，当前仍是关键帧 demo，后续需要专用动作和中间帧。源图、完整提示词、映射、核验图见 [art/sheets/README.md](art/sheets/README.md)。

## 工程内容

- `game/scripts/`：战斗、AI、界面、特效、程序合成音效与回归测试。
- `game/data/`：动作帧表、技能、属性、怪物与三波遭遇配置。
- `game/assets/demo/`：入库的正式 demo 帧条、背景、头像与动画清单。
- `art/characters/`：已确认角色参照；主角唯一造型标杆为 `hero_cool.png`。
- `art/sheets/`：新动作源图、提示词、几何报告、动作预览。
- `docs/design/`：既有设计；本轮实现和验收见 [战斗 demo v2 记录](docs/2026-10-14_战斗Demo优化与验收.md)。
- `tools/`：安装、启动、烘焙与旧预览工具。

旧 `game/art/` 继续作为被忽略的占位烘焙目录，demo 不再依赖它。`render_preview.py` 是历史手感验证器，不能用它的旧造型覆盖正式美术。`temp/`、`tools/godot/`、`game/.godot/` 不入库；设计结论与正式资源随 Git 提交。
