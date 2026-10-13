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
- 操作（M1 手感原型）：←/→ 移动（双击奔跑），C/空格 跳，X 普攻（三段连招），Z 上挑，V 格挡，↓+C 后跳；A~H 转职技能（T 切换转职调试：基础/狂战士/剑魂，R 重置战斗）
- 自动化验收：`tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --fixed-fps 60 --path game --quit-after 800 -- --test`（日志 grep `[M1]` 判定）
- 数据驱动：动作帧表/技能/怪物/玩家属性在 `game/data/*.json`，改完即生效

## 协作约定

- 所有策划/设计/会议结论必须写入 `docs/` 并随 git 提交。
- `temp/`、`tools/godot/`、`game/.godot/` 不入库；有价值的资源归档到 `art/` 后提交。
- 每次会话结束前：更新文档 + git 提交。
