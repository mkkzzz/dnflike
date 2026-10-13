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
├── temp/        # 临时预览产物（不入 git，见 .gitignore）
│   ├── preview/         # 旧程序渲染器产物
│   └── animation_tests/ # 动作帧实验
└── tools/       # 自研工具脚本
    ├── render_preview.py  # 骨骼动画手感预览渲染器
    └── make_anim.py       # AI 帧图 → 切帧/对齐/像素化/GIF
```

## 协作约定

- 所有策划/设计/会议结论必须写入 `docs/` 并随 git 提交。
- `temp/` 为临时产物，不提交；有价值的资源归档到 `art/` 后提交。
- 每次会话结束前：更新文档 + git 提交。
