# 技能教学原物品图像追加批次

| 字段 | 规格 |
|---|---|
| task_id / revision | dnf_teaching_items_native_v3 / 1 |
| owner / integration_owner | ws2 |
| asset_id | ui.item.original.1062、ui.item.original.1065；world.item.original.1062、world.item.original.1065 |
| 来源/授权 | 沿用户既定原素材路线，从111库按STK原icon/field image引用取帧；不生成、重绘或覆盖既有批次 |
| 图标规格 | 越桔28×28，consumption.img第4帧；魔力之花28×28，同IMG第7帧 |
| 地面规格 | 越桔33×22，FieldImage.img第21帧；魔力之花36×25，第32帧 |
| 像素与锚点 | 原生RGBA、原始尺寸和原偏移、normal/straight alpha，沿22原像素例外；单帧无动作时钟 |
| 输出 | `game_dnf/assets_local/items_original_v3/`；v1/v2保留原字节 |
| 构建 | `tools/bake_dnf_progression_icons.py --version items_original_v3 --ids original_1062,original_1065`；非空版本拒绝覆盖，检查用同版本--check |
| 依赖/验证 | `game_dnf/data/runtime_items.json`；原IMG/来源包/哈希/帧号/候选数在manifest登记，任务奖励与消耗品背包同包快验；用户视觉与原版一致性尚待试玩 |

原图无缩放重采样；运行时沿用既有像素工程的格子/地面显示规则，不称新制作2K图。源同路径多候选沿现有读取器优先级选择并保留证据，不据此确认实际加载的客户端版本。
