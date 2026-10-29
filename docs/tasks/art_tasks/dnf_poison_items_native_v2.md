# 毒香原物品图像追加批次

| 字段 | 规格 |
|---|---|
| task_id / revision | dnf_poison_items_native_v2 / 1 |
| owner / integration_owner | ws2 |
| asset_id | ui.item.original.4169、ui.item.original.20006、world.item.original.20006 |
| 来源/授权 | 沿用户既定DNF原素材路线；只读完整库，取原STK/EQU引用的IMG帧，不生成或重画 |
| 规格 | 源原生RGBA、原始尺寸与偏移、normal/straight alpha；每帧具体尺寸/IMG来源/SHA256在manifest登记，沿22原像素例外 |
| 输出 | `game_dnf/assets_local/items_original_v2/`；独立追加包，不覆盖首批v1 |
| 图标 | 毒药袋28×28，取原quest.img第92帧；项链28×28，取IconAcc.img第65帧 |
| 地面 | 项链17×18，取FieldImage.img第6帧；毒药袋原STK无field image，显式复用28×28图标，为适配显示 |
| 构建入口 | `tools/bake_dnf_progression_icons.py --version items_original_v2 --ids original_4169,original_20006`；非空版本拒绝重烘，检查用同版本的--check |
| 依赖/契约 | `game_dnf/data/runtime_items.json`；沿用原PNG/现有物品格与掉落锚点，单帧无动作时钟，稀有度由UI绘制 |
| 验证 | 原帧哈希、实际任务页/地面掉落/任务背包及奖励项链同一导出包；用户视觉与原版一致性尚待试玩 |

原始图像无缩放或重采样。运行时沿用现有像素工程的物品格/掉落显示缩放；不把它称为原生2K新资产。地图直接接收ws1已导出的猛毒雷鸣原图，不新增另一套怪物或地图美术。
