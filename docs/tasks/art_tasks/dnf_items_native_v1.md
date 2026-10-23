# 原生物品图标与管理界面 v1

| 字段 | 内容 |
|---|---|
| task_id / revision | dnf_items_native_v1 / 1 |
| asset_id | ui.item.training_coat、ui.item.training_necklace、ui.inventory.management |
| owner / integration_owner | ws2；其它区自行接收 |
| style / route | 用户既定DNF原生像素路线；原IMG只读解码、现有UI组件拼装，无生图/重绘 |
| 用途 | 数值模块样板装备进入普通背包与仓库，补齐每件图标及实例详情；不替换其它现有图标 |
| 状态 | 已发布；本区实装与渲染已检查，用户视觉复核待进行 |

## 单项规格与来源

| 语义ID | 原始脚本与图像 | 导出尺寸与锚点 |
|---|---|---|
| ui.item.training_coat | equipment/character/common/jacket/cloth/100050017.equ 的icon；sprite/item/common/coat.img，第335帧 | 原生28×28透明RGBA，偏移(0,0)，静态 |
| ui.item.training_necklace | equipment/character/common/amulet/100300001.equ 的icon；sprite/item/new_equipment/08_necklace/necklace.img，第69帧 | 原生28×28透明RGBA，偏移(0,0)，静态 |
| ui.inventory.management | 既有WindowCommon、原背包32步距网格与原按钮 | 460×488逻辑布局，单元图标28×28；原材质1:1拼装，无自绘替代 |

适用[22原生像素例外](../../design/22_资产画面规格.md)，800×600循环内容固定1080p居中显示，最近邻放大仅为像素显示。图标只提供外观；样板装备名称/品质/属性为E-ADAPT，不声称沿用原脚本装备身份或原版平衡。

## 依赖、复现与发布

- 原库来源：[asset_store.json](../../../game_dnf/asset_store.json)，IMG源SHA与选中包记录在导出manifest；保留原库，不修改源文件。
- 构建配方：[dnf_items_assets.py](../../../tools/dnf_items_assets.py)，输出独立 `assets_local/items_v1`，与城镇flow资源互不覆盖。
- 消费锁：[items_store.json](../../../game_dnf/items_store.json)，启动脚本检查本地版本/逐文件哈希，缺失后下载原私库不可变包；不需要完整提取库。
- [图标发布](https://github.com/mkkzzz/dnflike-assets/releases/tag/dnf-items-v1-20261023)。素材仍属原作，仅按用户既有私库共享授权使用。
- 实机从同一导出包载入两图；验证与截图见[交付记录](../../reports/ws2/2026-10/2026-10-23_统一物品背包与掉落拾取.md)。没有另外制作预览专用图。

本轮不改人物、动作、声音、时钟或武器混合契约。新图标/布局的技术检查通过，不能替代使用者审美认可。
