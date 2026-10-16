# 10001 森林背景重制 reference_redesign_v2

状态：源图制作（`source_review`）。2026-10-16 用户基本认可 R01 c2 的统一画风与构图，要求左右加少量灌木形成边界；已完成该修订与五房不同画幅的设计候选。新五房成品尚待用户评审，正式原生 2K 房间资源未完成。

## 1. 身份与需求

| 字段 | 约定 |
|---|---|
| task_id / revision | forest_10001_reference_redesign / reference_redesign_v2 |
| asset_type / workflow | 场景背景与地面 / 14 文档 F 路线 |
| style_profile / theme_pack | handpainted_action_v1 / dark_fantasy_v1（明亮森林地区） |
| owner / integration_owner | ws2 / 待分配 |
| scope | 10001-R01~R05 背景重制；本轮交左右低灌木修订与五房完整构图设计候选；实体、门、动画、音频及游戏接入另排 |
| replaces | 旧 lowres_release_v1 的五房已被用户拒绝并删除，本轮不复活旧包；新版获批后再建立正式替换映射 |

需求来源：[10001 设计单](../dungeon_tasks/10001_forest.md)与本轮指示“参考标准的那一版概念图”“每一个关卡场景都是一致的风格”。稳定子 ID：`scene.10001.r01.background` 至 `scene.10001.r05.background`，对应既定模块 ID，不改变布局 10001-A。

## 2. 依赖与影响

| 依赖 | 版本/批准依据 | 用途与影响 |
|---|---|---|
| [标准概念图](../../../art/concepts/scenes/forest/10001/v1/source/style_reference.png) | v1，2026-10-16 原批准“这波我觉得ok”，限风格/材质/设计方向 | 本轮最高视觉基准；改变须重评五房、独立道具与门的组合 |
| [旧作废结论](../../reports/ws1/2026-10/2026-10-16_10001房间场景作废结论.md) | 旧批次已弃用 | 禁止左右树木向内夹景、隧道构图与镜像延伸伪造长图 |
| [资产规格](../../design/22_资产画面规格.md) | 原生 2K、禁止放大 | 一屏 2560×1440；正式房间尺寸见下表；不以低清样张充当运行贴图 |
| [旧制作规格](../../../art/concepts/scenes/forest/10001/v1/production.json) | 保留原始分层/实体/门计划，未完成 | 其中工具能力描述属于旧会话；本轮真实能力以新生成记录为准 |

受影响下游为五房背景、道具/门的光向与比例组合、碰撞摆放、相机卷轴与房间入口配置。现行玩家/怪物动作、战斗事件、锚点、时钟与混合契约不变。未改游戏资源映射，不构成运行时替换。

## 3. 参考、工具与来源

- 输入均为仓库现有项目美术；仅沿用已有批准用途，无外部图片或外部游戏素材导入。
- 使用内置 `image_gen.imagegen`，通过 `referenced_image_paths` 实际传入标准图；五房首轮均同时传入标准图、获认可的 c2 和加边缘灌木的 c3。局部修订传入相应待改房间与 c2；实际输入逐次记录。
- 工具暴露 prompt、参考路径和透明背景开关；未暴露模型/seed/精确尺寸参数，模型版本与 seed 记未知。
- 一屏样张在 prompt 要求 2560×1440，五房请求下表正式尺寸；实际均未达标，以 [validation_batch_01.json](../../../art/concepts/scenes/forest/10001/reference_redesign_v2/validation_batch_01.json) 为准。没有重采样放大；当前是设计候选，非原生 2K 运行资源。
- 完整提示词、真实参考输入、哈希和原始结果记录见 [generation.json](../../../art/concepts/scenes/forest/10001/reference_redesign_v2/generation.json)。

## 4. 五房共同规格与区别

共同基准：低机位侧向三分之四横版视角，轻微俯看平地；屏内后草边约在 y=40%，其下为宽阔可行走平面；树干沿后方横向排列，包括画面中部，不从两侧夹出中央通道。青灰绿远景、深橄榄/苔绿树冠、灰棕树皮、暖棕细土地面；左上柔和日光，背景低对比。

| 房间 / 稳定子 ID 尾段 | 正式原生画布 | 同风格内的环境区别 | 本轮实际 |
|---|---|---|---|
| R01 / r01.background | 5120×1600 | 疏密适中的入口林地、平稳横向引导 | [room c1](../../../art/concepts/scenes/forest/10001/reference_redesign_v2/candidates/r01_room_c1/source.png)，实际 2243×701 |
| R02 / r02.background | 5120×1600 | 同树种与材质，树群间距略变化、远林更密 | [room c1](../../../art/concepts/scenes/forest/10001/reference_redesign_v2/candidates/r02_room_c1/source.png)，实际 2243×701 |
| R03 / r03.background | 3840×1600 | 同光向的紧凑林地，略密的后草带 | [room c2](../../../art/concepts/scenes/forest/10001/reference_redesign_v2/candidates/r03_room_c2/source.png)，实际 1942×809 |
| R04 / r04.background | 2816×3200 | 同林地增补高处树冠与镜头余量，地面仍平坦 | [room c1](../../../art/concepts/scenes/forest/10001/reference_redesign_v2/candidates/r04_room_c1/source.png)，实际 1176×1337；视口另列 |
| R05 / r05.background | 5120×1600 | 成熟树群横向散布、宽阔战斗空地；不加祭坛或新题材 | [room c1](../../../art/concepts/scenes/forest/10001/reference_redesign_v2/candidates/r05_room_c1/source.png)，实际 2243×701 |

所有房间真实新绘，不用镜像/平铺凑足尺寸；门、木桩、果树、火把、栅栏、骨堆及可交互独立灌木/石块不烘进背景。用户本轮新增的少量边缘灌木是非交互边界装饰，保留左右通行缺口，不自动增加碰撞。候选均为森林与地面一体 RGB、不透明 normal；原点左上、x 向右 y 向下，不翻转。正式分层、世界坐标、可行走边界、门位与相机范围仍需实装校验；不是分层成品。静态图时钟不适用。

R04 c2 曾尝试把地面起始线下移到全图 70%，实际未做到，内部拒用，保留源图和记录；当前选 c1。其预览采用明确窗口，给上方树冠和下方前景都保留余量，不再假定视口必须贴图片底边。各房预览裁切源像素坐标见技术报告；不把这些设计窗口冒充游戏已接入的相机或碰撞数据。

## 5. 样张与批准

| 候选 | 源文件 | 结论 |
|---|---|---|
| R01 c1 | [source.png](../../../art/concepts/scenes/forest/10001/reference_redesign_v2/candidates/r01_c1/source.png) | 内部检查发现后边界约在画面 56%，地面偏窄；保留追溯，修订为 c2，非用户否决记录 |
| R01 c2 | [source.png](../../../art/concepts/scenes/forest/10001/reference_redesign_v2/candidates/r01_c2/source.png) | 用户基本认可画风与构图；追加要求左右少量灌木营造边界感 |
| R01 c3 | [source.png](../../../art/concepts/scenes/forest/10001/reference_redesign_v2/candidates/r01_c3/source.png) | 按用户反馈局部加低矮边缘灌木，保留通行缺口；属于批准方向内的小改，成品未另获批准 |

批准原话：“基本认可，不过对于房间的左右侧，最好能有一点灌木丛，营造一些边界感”。范围是 c2 的画风/构图基准与边缘灌木修订，允许继续同风格五房候选；不等于新五房成品、原生分辨率或实机验收通过。各房均实际传入标准概念图、c2 和 c3，未更换工具/模型路线，不重复要求批准同一方向。

## 6. 加工与复现

源图保留工具原始字节，未裁切、调色、放大或抠图。包入口：[manifest.json](../../../art/concepts/scenes/forest/10001/reference_redesign_v2/manifest.json)。

从仓库根执行 `python art/concepts/scenes/forest/10001/reference_redesign_v2/build_review.py` 可重建本批检查报告、五房整图总览、同视口对照、c2/c3 边界修订对照及 c3 的 0.75 缩样。实际调用包内 `build_batch_review.py`，仅依赖 Pillow；只裁切/缩小评审副本，不改源图，不覆盖上轮历史 PNG。生成模型具有随机性，不声称可逐像素重生原画。

## 7. 校验与预览

- [五房整图总览](../../previews/forest_10001_reference_redesign_v2/batch_01/rooms_overview.png)：按实际画幅比例摆放，全图只缩小。
- [同视口对照](../../previews/forest_10001_reference_redesign_v2/batch_01/gameplay_viewports.png)：已认可 c2 与五房同原生视口比例裁切；不把不同长宽比的整图拉成一屏。暖色土地边线的颜色检测只帮助摆预览窗口，不是物理边界或美术验收。
- [左右灌木修改前后](../../previews/forest_10001_reference_redesign_v2/batch_01/r01_boundary_revision.png)、[c3 的 0.75 缩样](../../previews/forest_10001_reference_redesign_v2/batch_01/r01_c3_075.png)：相对实际源图缩小，**不是 1920×1080 验收证据**。
- [本批技术报告](../../../art/concepts/scenes/forest/10001/reference_redesign_v2/validation_batch_01.json)：PNG 解码、尺寸、RGB、源图与生成时哈希一致、实际参考与 prompt 引用、只缩小。通过；原生画布检查明确不通过。
- 人工观察：横向树群、宽阔平地、少量左右边缘灌木，未见角色/门/道具/UI；共同色光与材质接近 c2。局部土色与纹理密度仍有差异，五房最终美术认可待用户判断。
- 未完成：原生正式画布、四层导出、卷轴/门位与碰撞验证、真实角色组合与引擎实机检查。

## 8. 发布、接入与后续

候选随 Git 提交推送，提交不代表认可；实际发布 SHA 在当轮回复报告。接收方同步/实装状态由接收方填写。

- [x] 用户基本认可 c2 的画风、地面与横向树林构图，并要求左右补低灌木。
- [x] 完成 c3 边界小改与五房设计候选；逐房真实传图，并给出共同视口预览。
- [ ] 核实可产出原生正式画布的高分辨率路线；禁止把本样张放大。内置工具未提供尺寸参数；CLI/API 后备须用户明确选择，不能擅自切换。
- [ ] 用户评审新五房成品候选；批准记录不自动继承为新原图最终认可。
- [ ] 按正式画布完成分层/拼缝/门位适配及 2K、1080p 同包预览。
- [ ] 接收区核对版本，另行完成引擎接入、回归与用户实机验收。

## 9. 防复发

上一批根因是只传文字、误读横向树林，并用镜像延伸强化夹景；这轮保留真实参考输入与两次原图，先检查构图再给用户评审。新的能力限制是 prompt 中写尺寸并不能保证实际尺寸；必须读 PNG 实际像素，未达到原生规格时只标样张，不伪报正式成品。
