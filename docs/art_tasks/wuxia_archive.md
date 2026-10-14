# 武侠概念探索归档

2026-10-14。当前状态：**`on_hold`（搁置留档）**。用户最新决定：武侠方向先保留，将来作为其他独立工程；当前工程继续 DNF-like，由当前负责实装的工作区调试 V6。

本归档是 V1–V3 历史记录的最新状态入口。各版本文档和 `generation.json` 中的“待评审”等字段保留当时的制作状态；后续工作以本页的搁置决定为准。本轮没有新建独立工程或聊天，没有搬动、删改源图、提示词、参考图和预览。

## 状态与批准范围

| 事项 | 当前结论 |
|---|---|
| 武侠制作 | `on_hold`；暂停继续出图、批量动作和接入，保留全部资源 |
| 未来用途 | 候选独立武侠工程的参考资料；项目、工作区与实现方案待用户以后明确分配 |
| 整套风格批准 | **未获批准**；V2 的帅气获得肯定，不代表角色、场景、动作或全套美术获批 |
| 已有产出 | 对峙与拼刀静态概念、迭代反馈、完整实际提示词、参考输入和预览 |
| 动画与运行时 | **未实装、未实机验收**；静态概念不证明连续动作、运镜或拼刀机制成立 |
| 当前 DNF-like | 继续原有方向，V6 实装错位已修复并完成对位检查；武侠候选不替换现有角色、题材或资源包 |

V6 四招及配套效果的原有预览认可，不能转用于这组武侠候选。V6 调试与验收以 [V6 接入文档](../design/13_V6动作资源与实装待办.md) 和[本轮修复报告](../2026-10-14_V6实装错位修复与验收.md)为准。

## V1–V3 完整入口

下列路径均相对仓库保存，不依赖上传附件时的临时目录或生成器缓存。

| 版本 | 任务与反馈记录 | 源图目录 | 正式评审预览 | 完整实际提示词与生成记录 |
|---|---|---|---|---|
| V1：彩色水墨、背视构图初试 | [V1 文档](wuxia_backview_v1.md) | [源图与弃用原图](../../art/concepts/wuxia_backview_v1/) | [对峙](../previews/wuxia_backview_v1/idle_standoff.png)、[格挡](../previews/wuxia_backview_v1/weapon_parry.png)、[并排评审板](../previews/wuxia_backview_v1/battle_view_board.png) | [generation.json](../../art/concepts/wuxia_backview_v1/generation.json)；`sources[].prompt` 保存三次实际提示词 |
| V2：成熟侠客、近景拼刀与写实绘画 | [V2 文档](wuxia_backview_v2.md) | [源图与构图参考](../../art/concepts/wuxia_backview_v2/) | [对峙](../previews/wuxia_backview_v2/idle_standoff.png)、[拼刀](../previews/wuxia_backview_v2/weapon_parry.png) | [generation.json](../../art/concepts/wuxia_backview_v2/generation.json)；`sources[].prompt` 保存两次实际提示词 |
| V3：简化衣发、地面与背景大形 | [V3 文档](wuxia_backview_v3.md) | [源图与未选用初试](../../art/concepts/wuxia_backview_v3/) | [对峙](../previews/wuxia_backview_v3/idle_standoff.png)、[拼刀](../previews/wuxia_backview_v3/weapon_parry.png) | [generation.json](../../art/concepts/wuxia_backview_v3/generation.json)；`sources[].prompt` 保存三次实际提示词 |

保留的源文件与依赖：

- V1 的 `idle/` 保存对峙原图；`parry/` 保存选用格挡及有额外武器等问题的弃用图，选择与弃用原因见同版生成记录。
- V2 的 `idle_standoff_source.png`、`weapon_parry_source.png` 是选用原图；[reference_composition.png](../../art/concepts/wuxia_backview_v2/reference_composition.png) 是用户提供的游戏截图持久副本，仅用于构图和比例参考，不作为本工程或未来工程的实装美术。
- V3 的 `idle_standoff_source.png`、`weapon_parry_source.png` 是选用原图；[idle_attempt01.png](../../art/concepts/wuxia_backview_v3/idle_attempt01.png) 是细节仍过密的未选用初试。V3 依赖 V2 的人物/构图参考，未来复用时应一并保留。
- 三版各自的 `generation.json` 保留实际工具能力、参考输入、选用/弃用和已知限制；V2/V3 另记录实际尺寸、源/预览一致性与哈希。记录中的历史本机输出路径用于溯源，使用时以仓库内源图为入口。

## 反馈脉络与恢复条件

V1 被指出画风过于卡通、侠客气质不足、拼刀缺乏力量与张力。V2 按截图构图改成成熟侠客和近景交刃，用户肯定帅气，同时指出 AI 味重、细节过多、不像游戏画面。V3 因此简化衣装、发束、石板、山景和火星；其画风与游戏适配仍未获用户明确批准，随后按最新决定搁置。

将来只有用户明确恢复武侠方向并分配独立工程后，才确定新项目入口、批准范围和制作职责。届时先复核角色标准、同场风格与动作试点，再决定能复用的资料；不把这些候选静态图直接当成可接入动画或已验证战斗系统。
