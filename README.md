# 幽暗回廊 · DNF-like

原创手绘风单机横版动作 RPG，Godot 4.7.2。当前交付**战斗 demo**：三波遭遇、双转职与连段训练；三段普攻与拔刀斩使用角色与剑一体的原画 + 分层序列帧特效。

> 参与开发先读 [AGENTS.md](AGENTS.md)。当前进度见 [进度看板](docs/project/01_进度看板.md)，全部文档见 [文档索引](docs/project/07_文档索引.md)。

**原生像素新版验证**：[game_dnf](game_dnf/README.md)，本机运行 `tools/run_dnf.ps1`。使用本地 DNF 资源，素材不上传；下方原工程保留作玩法对照。

## 开始试玩

```powershell
# 首次：安装指定引擎（必须 4.7.2，其它版本会改写导入文件，启动脚本会拒绝）
powershell -NoProfile -ExecutionPolicy Bypass -File tools/setup_godot.ps1

# 启动
powershell -NoProfile -ExecutionPolicy Bypass -File tools/run_demo.ps1
```

也可用 Godot 4.7.2 打开 `game/project.godot` 按 F5；自备 4.7.2 引擎可传 `-GodotPath "C:\path\godot.exe"`。正式贴图与音频已入库，无需 Python 或重新烘焙。

操作键位、帧率设置与玩法入口见 [战斗系统](docs/design/06_战斗系统.md#当前实机操作与设置)。

## 验证

```powershell
# 战斗与集成回归（headless，固定 60 Hz；当前项数见进度看板）
powershell -NoProfile -ExecutionPolicy Bypass -File tools/run_demo.ps1 -Test

# 真实渲染截图 → temp/demo/
powershell -NoProfile -ExecutionPolicy Bypass -File tools/run_demo.ps1 -Capture

# 文档：链接、路径、表格、体积规范
python tools/check_docs.py
```

## 资源重建（仅修改美术 / 音频源时）

```powershell
python -m pip install -r requirements.txt
python tools/bake_body_v3.py; python tools/bake_body_v4.py; python tools/bake_combat_audio.py
python tools/bake_seq_v6.py; python tools/test_seq_v6.py; python tools/preview_v6.py
```

## 目录

| 目录 | 内容 |
|---|---|
| `game/` | Godot 工程：脚本、数据、实装资源 |
| `art/`、`audio/` | 美术与音频源文件、生成记录、导出 |
| `tools/` | 安装、启动、烘焙、录像、校验与开工同步脚本 |
| `docs/` | 项目中枢、设计、过程记录、任务包、评审证据 |

演示：[V6 四招](docs/previews/combat_v6_showcase.mp4) · [V4（含音效）](docs/previews/combat_v4_showcase.mp4) · 截图在 `docs/screenshots/`
