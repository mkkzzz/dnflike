# 主 HUD 参考还原 v2

## 1. 身份与需求

| 字段 | 约定 |
|---|---|
| task_id / asset_id | hud_reference_v2 / ui.hud.reference_sample |
| revision / replaces | reference_v2.c1；旧 theme_v1 退回，保留历史 |
| asset_type / workflow | UI / 14 文档 H 路线 |
| style_profile / theme_pack | handpainted_action_v1 / dark_fantasy_v1；金属材质以本轮截图为准 |
| scope | 已认可样张 → 独立资源 → 运行时 HUD；本轮完成接入 |
| gameplay_purpose | 战斗血蓝、道具、技能、目标、小地图、连击及评价的信息分层 |
| owner / integration_owner | ws2 / ws2 |
| lifecycle | c1 source_approved；运行时接入已发布，待用户实机试玩验收 |

用户要求：此前其他 agent 的 UI 效果差，基本还原本轮截图；资源重新生成，不使用简单色块。
本轮按 [美术流程](../../design/14_美术资源全流程.md)先提供具体样张待人工看图；沿用双排 12 技能格、默认两个技能、队伍暂不显示、轮盘功能预留的既有需求。

2026-10-18 用户确认“风格我很认可，好非常多”，并授权“出一版资源”“拼起来看看”。[首批交付入口](../../../art/ui/hud/reference_v2/batch_01/README.md)已生成独立源图、透明导出与同包拼装；本批尺寸以 batch_01 的 manifest/layout 为准。

## 2. 依赖与影响

- [旧设计](../../design/24_主HUD设计.md)提供功能需求；新图纠正其装饰过重、试管血蓝槽与松散底栏。
- 旧源资源 `art/ui/hud/theme_v1/` 保留；现行 `game/scripts/hud.gd` 已消费 `game/assets/ui/hud_v2/` 的正式导出。
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

上述源图/离线拼装是历史评审阶段。用户随后明确要求“把 UI 实装一下”，本轮已接真实血蓝、冷却、地图与连击；轮盘仅齿轮接显示设置，经验尚无系统而保持空轨，评价占位与假道具不显示。源风格批准未扩展为用户实机验收。

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
- 2026-10-18 按用户追加要求，Godot 4.7.2 实际运行当前工作区的 10001-R01/R02，隐藏旧 HUD/设置覆盖层并截取 1920×1080 原图：[入口房叠图](../../previews/hud_reference_v2/current_game/entrance_new_hud_1920.png)、[有怪房间叠图](../../previews/hud_reference_v2/current_game/encounter_new_hud_1920.png)。独立资源按 0.75 叠加；无 UI 的[实拍源图与状态](../../screenshots/hud_environment)完整保留，HUD 外场景像素校验未变。目标/血蓝/房间号来自本次状态，经验保持 0%；道具栏和小地图仍为样式预览，未实装新 HUD。
- 复现脚本：`art/ui/hud/reference_v2/batch_01/capture_current_scene.gd`（Godot 指定 --path game --script 绝对路径，建议 --resolution 1920x1080 --position -32000,-32000），将 temp 输出复制到上述实拍目录后运行 `python art/ui/hud/reference_v2/batch_01/compose_current_scene.py`。不修改游戏代码、场景或资源配置。

## 8. 发布、后续接入与验收

按协作规则独立提交和推送本轮产物，保留同工作区并行 v7 改动。发布结果由本轮回复说明。

- [x] 用户批准 c1 整体风格并授权首批资源与拼装。
- [x] 按上表生成独立静态资源并检查真实尺寸/透明边缘。
- [x] 导出与预览共用包，演示液面/玻璃/冷却/运行时文字分层。
- [x] 用户授权从当前场景叠图继续正式实装。
- [x] 接入既有 HUD 数据入口、让位行为、双排技能键及真实小地图。
- [x] 完成双分辨率实机截图与相关回归，见[实装记录](../../reports/ws2/2026-10/2026-10-18_主HUD实装与验证.md)。
- [ ] 用户实机试玩与最终视觉验收。

## 9. 修改复盘

旧版把参考的克制金属/粗胶囊/紧密嵌槽解释成亮金繁饰/试管/大空白；先逐区比较实际画面与参考，再拆组件。正式出图仍须实测返回像素，prompt 的目标尺寸不是原生 2K 的证据。

## 10. 运行时接入

- [运行时资源清单](../../../game/assets/ui/hud_v2/manifest.json)记录源文件、尺寸、哈希与实际使用情况；首批贴图逐字节复用，追加狂战士血怒/怒斩两图的[生图记录](../../../art/ui/hud/reference_v2/runtime_additions/generation.json)保留真实参考、完整提示词和原始输出。两图原生 1254×1254，仅缩小为 96×96。
- HUD 使用 2560×1440 原生画布，缩到逻辑坐标，canvas_items 在实际窗口分辨率重绘。1080p 纹理 0.75，2K 纹理 1.0；底板镜像平铺，目标长条重复中段，装饰不拉大。
- 技能 QWERTY/ASDFGH 可点击、拖换并按职业保存；默认 A/S 放现有职业技能，冷却及缺蓝状态跟技能身份走。道具只显示可实际使用的红/蓝药，其他槽空着；数字 1/2 保持原有用药行为。
- 移除旧常驻提示/显示设置按钮/大 FPS、假评价与调试数值、房间内部模块 ID 和未实现回城按钮。左上只留小 FPS，轮盘齿轮或 F3 打开实际显示设置。隐藏的 P 开发面板保留供项目调试，不常驻显示。
- [1080p 实机](../../screenshots/hud_v2/live_1920.png)、[血蓝/冷却状态](../../screenshots/hud_v2/states_1920.png)、[2K 实机](../../screenshots/hud_v2/live_2560.png)均由引擎帧缓冲直接保存；前述 current_game 目录仍是历史离线叠图，不能混用。
