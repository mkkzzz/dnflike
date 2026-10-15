# 幽暗回廊 · DNF-like

原创手绘风单机横版动作 RPG，Godot 4.7.2。当前交付**战斗 demo**：三波遭遇、双转职与连段训练；三段普攻与拔刀斩使用角色与剑一体的原画 + 分层序列帧特效。

> **开工前必读**：[协作总纲](docs/project/00_协作总纲.md) → [进度看板](docs/project/01_进度看板.md) → [待办](docs/project/02_待办.md)。
> 全部文档见 [文档索引](docs/project/07_文档索引.md)。

## 开始试玩

```powershell
# 本机已有 Godot 时直接运行
powershell -NoProfile -ExecutionPolicy Bypass -File tools/run_demo.ps1

# 新机器先安装引擎，再按上一步启动
powershell -NoProfile -ExecutionPolicy Bypass -File tools/setup_godot.ps1
```

也可以用 Godot 打开 `game/project.godot` 后按 F5 运行。自备引擎可向启动脚本传入 `-GodotPath "C:\path\godot.exe"`。正式贴图与 WAV 已入库，首次拉取无需安装 Python 或重新烘焙。

**操作键位、帧率设置与系统细节**见 [战斗系统设计](docs/design/06_战斗系统.md#当前实机操作与设置)。

## 验证

```powershell
# 271 项战斗与集成检查（headless，固定 60 Hz）
powershell -NoProfile -ExecutionPolicy Bypass -File tools/run_demo.ps1 -Test

# 真实渲染截图 → temp/demo/
powershell -NoProfile -ExecutionPolicy Bypass -File tools/run_demo.ps1 -Capture

# 文档一致性：链接有效性与目录规范
python tools/check_docs.py
```

## 演示与证据

- [V6 四招实机演示](docs/previews/combat_v6_showcase.mp4)
- [V4 实机演示（含音效）](docs/previews/combat_v4_showcase.mp4)
- 实机截图：`docs/screenshots/`

## 资源重建（仅修改美术 / 音频源时需要）

```powershell
python -m pip install -r requirements.txt
python tools/bake_body_v3.py
python tools/bake_body_v4.py
python tools/bake_combat_audio.py

# V6 序列帧重烘与预览
python tools/bake_seq_v6.py
python tools/test_seq_v6.py
python tools/preview_v6.py
```

## 目录速览

| 目录 | 内容 |
|---|---|
| `game/` | Godot 工程：脚本、数据、实装资源 |
| `art/` | 美术源图、生成记录、导出资源 |
| `audio/` | 正式拟音 |
| `tools/` | 安装、启动、烘焙、录像与校验脚本 |
| `docs/` | [项目中枢](docs/project/00_协作总纲.md)、[设计](docs/design/)、[过程记录](docs/reports/)、[任务包](docs/tasks/) |

详细工程结构、资源清单与管线说明见 [文档索引](docs/project/07_文档索引.md)。
