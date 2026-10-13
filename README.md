# dnf

怀旧风横版动作 RPG（单机）。原创美术/音频，还原经典横版动作网游的手感与系统。

## 目录结构

```
dnf/
├── docs/        # 策划案、设计案、工作记录（全部工作内容落盘于此并随 git 提交）
├── art/         # 正式美术资源
│   ├── characters/     # 角色标杆图、头像
│   └── environments/   # 场景背景
├── audio/       # 音频资源（音效、BGM）
├── game/        # Godot 4.7 工程
│   ├── project.godot
│   ├── scenes/Main.tscn
│   └── scripts/
├── temp/        # 临时预览产物（不入 git，见 .gitignore）
└── tools/       # 自研工具脚本
    ├── setup_godot.ps1    # 新机器一键安装 Godot
    ├── render_preview.py  # 骨骼动画手感预览渲染器
    └── make_anim.py       # AI 帧图 → 切帧/对齐/像素化/GIF
```

## 运行

- 本机：`tools/godot/Godot_v4.7.2-stable_win64.exe --path game`
- 新机器：先跑一次 `tools/setup_godot.ps1`，再按上一步启动；或手动下载同版本 Godot 后打开 `game/project.godot`
- 操作：A/D 或方向键移动，C 跳跃，X 普攻（M1 占位实现）

## 协作约定

- 所有策划/设计/会议结论必须写入 `docs/` 并随 git 提交。
- `temp/`、`tools/godot/`、`game/.godot/` 不入库；有价值的资源归档到 `art/` 后提交。
- 每次会话结束前：更新文档 + git 提交。
