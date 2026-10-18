# HUD v2 首批独立资源

2026-10-18 用户明确认可 c1 风格并要求“出一版资源”“拼起来看看”。本批已出独立资源与同包拼装，状态 baked_validated；本批美术评审和游戏接入待后续。

- 20 件 UI 源图逐件由内置 image_gen 生成，另有一张清理 HUD 的场景评审底图。完整提示词放 prompts，未改原始输出放 sources。
- 22 张独立 RGBA 导出放 exports：左右空壳、红蓝液面、两张派生玻璃高光、轮盘、槽框、平铺底板、经验框、目标框/头像、小地图框、标题牌、六件道具和两个技能图标。
- 制作：每件实际传入已批准 c1；右壳额外传入左壳以约束结构。模型版本/种子工具未返回，未知。参考顺序与真实尺寸/哈希见 manifest。
- 原生布局：2560×1440；1080p 整体 0.75 缩小。每件源图均足够其 2K 显示尺寸；无源像素放大、无非等比拉伸。
- 底板只做 mirrored_repeat 等比平铺；所有框体、金属材质、图标来自生图。文字、键位小牌、地图小标记、血条进度及冷却遮罩是运行时层。
- HP/MP 空壳、液面、高光同为 248×384 对齐画布。液面按 manifest 的 well_xywh 从下向上裁切；高光保持静态。高光从同一生图近白亮部提取，不计作新增原画。
- 部分生成器边缘有低 alpha 光晕：以 alpha>200 的主体包围盒加 2px 安全边裁切，不用 RGB 色键，以免误吃暗部金属。降采样在预乘空间进行，输出转回 straight alpha。
- 布局按 c1 屏占比校正：两端 248×384、轮盘 480×410、底板 2560×270、槽框 116×116 加运行时键位；精确坐标见 layout。

## 消费包

- 入口 manifest.json：textures 的 file 相对本目录，export_path_base=package_root；source/export 字段则保留仓库路径用于追溯。
- layout.json：2K 坐标与示意状态；1080p 统一乘 0.75。
- hud_reference_v2_batch_01.zip：自包含消费包（exports、manifest、layout、validation、本文），无字体依赖；源图/提示词/加工脚本保存在仓库同目录。
- 只运行 `python art/ui/hud/reference_v2/batch_01/build_pack.py` 可离线重建导出、拼装、校验与 ZIP；需要 Pillow。重新运行随机生图不保证字节一致。
- PNG 普通 straight-alpha 混合；不使用加法。所有文本由接入方渲染，PNG 不包含键位、等级、数量、冷却秒数或目标名。

## 预览

- [整体拼装](../../../../../docs/previews/hud_reference_v2/batch_01/assembled_scene.png)：实际导出贴图缩小后叠到 1672×941 原生评审场景，场景没有放大；经验 62% 仅作效果示意。
- [半血/冷却](../../../../../docs/previews/hud_reference_v2/batch_01/assembled_states.png)：64% HP、82% MP、冷却遮罩与数值，验证独立层。
- [2K 原像素底栏](../../../../../docs/previews/hud_reference_v2/batch_01/bottom_native_2560.png)与[1080p 比例底栏](../../../../../docs/previews/hud_reference_v2/batch_01/bottom_1080_scale.png)：实际 0.75 缩样与透明边缘检查；默认经验为 0%。
- [资源总览](../../../../../docs/previews/hud_reference_v2/batch_01/asset_contact_sheet.png)：逐件实际导出。

## 当前边界

- 本批是离线拼装，未运行 Godot，未改现行 HUD、键位或战斗数据。整屏图不是正式场景或人物替换，不当作实机证据。
- 道具图标和增益栏样式用于评审，未声明已经有道具/增益系统；两个技能图标对应现有 quick_draw/thrust，轮盘功能仍留空。
- 经验/目标血量/地图/连击/评价都是示意值；接入时经验系统未实现应保持 0%，其他数据需绑定真实来源。
- 本批通过尺寸/透明/缩放/引用/布局检查；源风格已获认可，本批最终美术认可与双分辨率实机验收尚未完成。
