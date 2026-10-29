# 原任务奖励与药剂图标批次 v1

| 字段 | 规格 |
|---|---|
| task_id / revision | dnf_progression_native_v1 / 1 |
| owner / integration_owner | ws2 |
| asset_id | ui.item.original.<原物品ID>；world.item.original.<原物品ID> |
| 范围 | 本批运行表中的原任务奖励装备与HP/MP药剂；保留旧图标包 |
| 来源与授权 | 用户既定DNF原生素材路线及本轮原物品实装授权；只读现有原库，按原EQU/STK的icon/field image取帧，无生图或重绘 |
| 风格/规格 | 22文档原生像素例外；图标按原帧尺寸透明RGBA，实际尺寸与原偏移逐项登记在manifest；不缩放、不描画、不改字 |
| 静态契约 | 单帧，无动作时钟；UI原点及世界原偏移分开记录，normal/straight alpha；稀有度边框由现有UI绘制 |
| 输出 | `game_dnf/assets_local/items_original_v1/`，新版本目录，不覆盖items_v1/items_v2 |
| 构建入口 | `tools/bake_dnf_progression_icons.py`，由运行表逐项驱动，来源IMG哈希/包/帧/原尺寸登记 |
| 验收 | 源哈希、引用、尺寸/透明度、导入与实际背包/任务选奖/药剂快捷栏同包验证；预览认可不替代用户实机视觉验收 |

资源依赖为当前完整库、原IMG读取器及`game_dnf/data/runtime_items.json`。运行资源按现行28契约随仓库分发，不依赖其它机器有本地PVF或temp。未发布前状态为进行中，最终验证见本批实装报告。
