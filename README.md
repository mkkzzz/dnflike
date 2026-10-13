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
│   ├── art/                # 烘焙贴图（不入 git，由 bake_game_assets.py 生成）
│   ├── scenes/Main.tscn
│   └── scripts/
├── temp/        # 临时预览产物（不入 git，见 .gitignore）
├── tools/       # 自研工具脚本
│   ├── setup_godot.ps1      # 新机器一键安装 Godot
│   ├── bake_ai_frames.py    # 【正式】AI 动作帧图 → 角色/怪物帧条
│   ├── ai_anim_spec.json    # AI 出图规格 + 待定的尺度/手感参数
│   ├── make_anim.py         # 帧图处理算法（绿幕抠图/切帧/脚底对齐/像素化）
│   ├── bake_game_assets.py  # 【占位】程序化几何 → 帧条 + 背景 + 暗角
│   ├── bake_hud.py          # 【占位】程序化 HUD 静态层
│   └── render_preview.py    # 手感验证预览渲染器（**不是美术源**，见 11 文档）
└── requirements.txt       # Python 工具链依赖
```

## 运行

- 本机：`tools/godot/Godot_v4.7.2-stable_win64.exe --path game`
- 新机器：先跑一次 `tools/setup_godot.ps1`，再按上一步启动；或手动下载同版本 Godot 后打开 `game/project.godot`
  - 若被系统执行策略拦截（`禁止运行脚本`），用 `pwsh -ExecutionPolicy Bypass -File tools/setup_godot.ps1`
- Python 工具链（仅 `tools/` 下的预览/切帧/烘焙脚本需要）：`python -m pip install -r requirements.txt`
- 美术烘焙（产物 `game/art/` 不入库，换机器/改美术后重跑）：
  - **正式**：`python tools/bake_ai_frames.py` —— AI 动作帧图 → 角色/怪物帧条（规格见 `tools/ai_anim_spec.json`）
  - **占位**：`python tools/bake_game_assets.py` —— 程序化几何图形当占位；**不会覆盖**已有 AI 帧条
  - `python tools/bake_hud.py` —— HUD 静态层
- 美术方向：定稿标杆 = `art/characters/hero_cool.png`（黑皮风衣+血红内衬+红挑染）。
  `benchmark_board.png` / `hero_idle.png` / `hero_attack.png` 是**已弃用旧方案**，勿参照。
  详见 [docs/design/10_美术与音频管线.md](docs/design/10_美术与音频管线.md)
- 操作（M1 手感原型）：←/→ 移动（双击奔跑），C/空格 跳，X 普攻（三段连招），Z 上挑，V 格挡，↓+C 后跳；A~H 转职技能（T 切换转职调试：基础/狂战士/剑魂，R 重置战斗）
- 自动化验收：`tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --fixed-fps 60 --path game --quit-after 800 -- --test`（日志 grep `[M1]` 判定）
- 数据驱动：动作帧表/技能/怪物/玩家属性在 `game/data/*.json`，改完即生效

## 协作约定

- 所有策划/设计/会议结论必须写入 `docs/` 并随 git 提交。
- `temp/`、`tools/godot/`、`game/.godot/` 不入库；有价值的资源归档到 `art/` 后提交。
- 每次会话结束前：更新文档 + git 提交。
