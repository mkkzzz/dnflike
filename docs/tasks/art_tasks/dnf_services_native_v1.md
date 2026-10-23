# 原生回城服务界面与材料图标

| 字段 | 内容 |
|---|---|
| task_id / revision | dnf_services_native_v1 / 1 |
| asset_id | ui.item.scrap_iron、ui.town.services |
| 路线/规格 | 既定DNF原生像素例外，原IMG只读解码与现有UI组件拼装；不生图、不放大重制 |
| owner / integration_owner | ws2，其它区按锁自行接收 |
| 用途 | 出售/回购、分解与耐久/修理的操作、报价和结果展示 |
| 状态 | 已发布；本区技术检查，用户视觉复核待进行 |

## 素材规格与来源

- 铁质碎片：`stackable/material/piece_iron.stk` 的icon字段指向sprite/item/iconmaterial.img第3帧，原生28×28透明RGBA、偏移(0,0)；不修改原像素或编造素材。
- 导出manifest保存源脚本路径、IMG SHA、NPK选择、帧号、裁切偏移与尺寸。名称/材料用途和经济规则是E-ADAPT。
- 新服务窗口460×488、确认框396×224，复用原WindowCommon/商店纹理、28图标/32网格与原按钮；布局为适配，中文运行时文字层。保持800×600逻辑画面和固定1080p像素呈现。
- 同一items v2包保留布甲/项链的原像素；旧items v1目录与已发布字节保留，不覆盖。城镇/战斗flow包不被本任务重打。

依赖：[22原生像素例外](../../design/22_资产画面规格.md)、[原物品任务](dnf_items_native_v1.md)、[items消费锁](../../../game_dnf/items_store.json)、[构建/安装工具](../../../tools/dnf_items_assets.py)。

发布：[items v2私库](https://github.com/mkkzzz/dnflike-assets/releases/tag/dnf-items-v2-services-20261023)。原素材仍属原作，仅按用户既定私库共享授权使用。实机直接载入这份包，没有另作预览图；验证见[当轮记录](../../reports/ws2/2026-10/2026-10-23_回城交易分解与耐久服务.md)。
