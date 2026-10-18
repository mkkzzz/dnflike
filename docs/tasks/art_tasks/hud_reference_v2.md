# 主 HUD 参考还原 v2

## 1. 身份与需求

| 字段 | 约定 |
|---|---|
| task_id / asset_id | hud_reference_v2 / ui.hud.reference_sample |
| revision / replaces | reference_v2.c1；旧 theme_v1 退回，保留历史 |
| asset_type / workflow | UI / 14 文档 H 路线 |
| style_profile / theme_pack | handpainted_action_v1 / dark_fantasy_v1；金属材质以本轮截图为准 |
| scope | 整屏方向样张；批准后再出独立可接入资源 |
| gameplay_purpose | 战斗血蓝、道具、技能、目标、小地图、连击及评价的信息分层 |
| owner / integration_owner | ws2 / ws2（后续接入任务） |
| lifecycle | c1 source_approved；首批独立资源 baked_validated，待本批美术评审、未实装 |

用户要求：此前其他 agent 的 UI 效果差，基本还原本轮截图；资源重新生成，不使用简单色块。
本轮按 [美术流程](../../design/14_美术资源全流程.md)先提供具体样张待人工看图；沿用双排 12 技能格、默认两个技能、队伍暂不显示、轮盘功能预留的既有需求。

2026-10-18 用户确认“风格我很认可，好非常多”，并授权“出一版资源”“拼起来看看”。[首批交付入口](../../../art/ui/hud/reference_v2/batch_01/README.md)已生成独立源图、透明导出与同包拼装；本批尺寸以 batch_01 的 manifest/layout 为准。

## 2. 依赖与影响

- [旧设计](../../design/24_主HUD设计.md)提供功能需求；新图纠正其装饰过重、试管血蓝槽与松散底栏。
- 旧源资源 `art/ui/hud/theme_v1/` 保留；现行 `game/scripts/hud.gd` 为后续消费者，本轮未改。
- 参考场景和人物由本轮生图绘制，仅辅助 HUD 的观感/尺度；不替换已批准的森林与角色资源。
- 下游须分别制作静态框体、透明液面/高光、图标、状态层，并运行时排字；现行 set_*、底栏让位、动作/特效时钟保留。

## 3. 参考、来源和真实工具能力

- 参考：用户本轮附件，1112×832；SHA256 `fcf439290346af4afefd83be6d3c7f71b5af943818d73e2a0872cd668a9bf5b6`。仅用于参考，不裁源图像素作游戏资源。
- 工具：内置 `image_gen.imagegen`，通过 referenced_image_paths 实际传入附件；非仅在 prompt 写路径。
- c1 调用 transparent_background=false，输出 RGB 整屏样张。首批资源逐件调用 true（平铺底板和清理场景除外），已验证实际 RGBA/真实透明边缘。
- 实际模型版本和随机种子：工具未返回，未知；不沿用旧 agent 的模型名。
- [完整提示词](../../../art/ui/hud/reference_v2/candidates/c1/prompt.txt)及[原始输出](../../../art/ui/hud/reference_v2/candidates/c1/source.png)保留在包内。提示词总结：紧凑贴边、铜灰磨旧材质、粗实红蓝胶囊、内凹格子、绿色弧线半轮盘、双排技能、小地图；避免金饰、试管及平面色块。

## 4. 尺寸、层级与后续独立资源规格

正式布局目标 2560×1440；1080p 只缩至 0.75。c1 请求 2560×1440，实际仅 **1672×941 RGB**，保留原尺寸作为方向样张；禁止放大或宣称已交付 2K。

| 独立语义 ID | 正式 2K 显示尺寸/范围 | 制作要求 |
|---|---|---|
| ui.hud.orb_hp / orb_mp | 外壳各 248×384；位于左右底角 | 保留既有 ID，外观改粗胶囊；壳体/液面/玻璃高光分开 |
| ui.hud.panel_bottom | 2560×270，贴底；512×270 平铺纹理 | 等比 mirrored_repeat 平铺，不放大低清长条 |
| ui.hud.slot_frame | 116×116；运行时键位另加底牌 | 源图每格不小于目标像素；不得把动态内容烘入 |
| ui.hud.wheel | 480×410；下缘按屏幕自然裁切 | 五个外围小钮加中央钮，沿用已认可 c1 视觉，功能仍留空 |
| ui.hud.exp_track | 790×70 | 框与进度分开；真实经验系统未实现时 0%；预览另给示意填充 |
| ui.hud.buff_frame | 64×64 | 以实际状态填内容，样张图标不是已实现增益 |
| ui.hud.target_frame | 820×116 | 头像/目标文字/血条独立；保留旧设计的动态条长及层数需求 |
| ui.hud.minimap_frame | 260×285，右上 | 边框独立；真实地图数据接入另行实现 |
| ui.hud.dungeon_title | 620×64，右上 | 酒红珐琅空牌与运行时文字分开 |
| ui.hud.skill_icon / item_icon | 内嵌图标 96×96 | 两个技能对应 quick_draw/thrust；六件道具按 c1 做资源示意 |

技能区保持 2×6；道具 6 格；轮盘/两端壳体与底板连接，消除旧稿大空档。正式字体运行时渲染；动画/事件/朝向在静态样张不适用。后续 PNG 用 straight alpha 普通混合；本轮 RGB 不冒充透明切图。

## 5. 源图与批准

| 候选 | 实际交付 | 状态 |
|---|---|---|
| c1 | 一张新生成完整画面，带场景/人物/静态示意数值 | 用户已认可整体风格；不作为生产图集 |
| batch_01 | 20 件新 UI 源图、1 张清理场景；22 张独立导出（含 2 张派生高光） | 技术校验通过；拼装待本批美术评审 |

轮盘功能、真实地图/经验/评价的数据接入未完成；图上的数值/标签仅用于评审。源风格批准未扩展为游戏实装验收。

## 6. 加工与复现

- 包入口：`art/ui/hud/reference_v2/manifest.json`；校验：`art/ui/hud/reference_v2/validation.json`。
- `python art/ui/hud/reference_v2/build_review.py` 从原始输出生成 0.75 缩样与原像素底栏裁图，保存尺寸/哈希/是否放大等事实。
- 原始输出未改；不声称可复现随机生图。原参考为用户附件，后续重新生图需要附件图像输入或明确的新参考。
- 首批加工：`python art/ui/hud/reference_v2/batch_01/build_pack.py`，需要 Pillow。逐件 alpha 主体裁切、预乘降采样、液面遮罩、玻璃亮部提取与同包拼装；未放大、未用色键抠暗金属。可消费 ZIP 入口见首批 README。

## 7. 校验和预览

- 原始整屏：[source.png](../../../art/ui/hud/reference_v2/candidates/c1/source.png)。
- [原像素底栏细节](../../previews/hud_reference_v2/c1_bottom_detail.png)；[实际源图的 0.75 缩样](../../previews/hud_reference_v2/c1_actual_075.png)。该缩样不是 1920×1080 成品。
- 检查源图解码、实际尺寸、SHA256、缩样不放大及文档链接。未运行 Godot，不把离线示意图记成实机截图。
- [首批整屏拼装](../../previews/hud_reference_v2/batch_01/assembled_scene.png)、[半血/冷却](../../previews/hud_reference_v2/batch_01/assembled_states.png)、[原生 2K 底栏](../../previews/hud_reference_v2/batch_01/bottom_native_2560.png)、[1080p 比例底栏](../../previews/hud_reference_v2/batch_01/bottom_1080_scale.png)。整屏场景保持原生 1672×941，叠加从 2K 缩小的 UI；不宣称场景本身已成为 2K 正式资产。

## 8. 发布、后续接入与验收

按协作规则独立提交和推送本轮产物，保留同工作区并行 v7 改动。发布结果由本轮回复说明。

- [x] 用户批准 c1 整体风格并授权首批资源与拼装。
- [x] 按上表生成独立静态资源并检查真实尺寸/透明边缘。
- [x] 导出与预览共用包，演示液面/玻璃/冷却/运行时文字分层。
- [ ] 用户评审本批资源实际组合；真实数据按游戏接入任务绑定。
- [ ] 接入既有 HUD 数据入口、让位行为、双排技能键及真实小地图。
- [ ] 2560×1440 与 1920×1080 实机截图、相关回归与用户实机验收。

## 9. 修改复盘

旧版把参考的克制金属/粗胶囊/紧密嵌槽解释成亮金繁饰/试管/大空白；先逐区比较实际画面与参考，再拆组件。正式出图仍须实测返回像素，prompt 的目标尺寸不是原生 2K 的证据。
