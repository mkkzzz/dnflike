# 任务：鬼剑士标准原画设定 standard_v1

| 字段 | 内容 |
|---|---|
| asset_id | `char.swordsman.standard` |
| revision | standard_v1 |
| 状态 | **源图已批准，锁定**（2026-10-15；负责人认可 ws1 建议并授权收尾锁定，见 [D030](../../design/决策清单.md)） |
| 身份来源 | V6 造型（[D027](../../design/决策清单.md)），以 V6 forehand 起手帧为参照 |
| 工具 | 文字生图（无参考图输入）；完整提示词见 `art/concepts/characters/players/swordsman/standard_v1/generation.json` |
| 源文件 | `art/concepts/characters/players/swordsman/standard_v1/`，索引 `manifest.json` |
| 评审 | `docs/previews/standard_v1/standard_sheet.jpg`（设定集总图） |
| 规划 | [18 角色锚定与动作管线](../../design/18_角色锚定与动作管线.md) 第七节 |

## 一、标准身份规格（2026-10-15 负责人确认，随母版 c1 锁定）

**文字规格优先于图**：图与规格冲突时，以下表为准。

| 项 | 规格 |
|---|---|
| 体型 | 精瘦健壮的青年男性；母版实测约 8 头身（含刺发高度） |
| 发型 | 银白乱刺发，一缕深红挑染在**角色自己的右前额**：正面看在观者左侧；朝右的游戏视角里朝向镜头、可见 |
| 眼睛 | 深灰色 |
| 风衣 | 黑皮长风衣到小腿中部，立领 + 翻驳领，领口 / 衣襟 / 内摆露深红内衬；袖子卷到前臂中段 |
| 内衣 | 黑色贴身高领 |
| 束带 | 胸前两道银扣横向皮带 + 银扣腰带；右大腿一道细绑带 |
| 手臂 | 双手与前臂缠深红布绷带到肘部，露指，无火焰；手臂上**没有金属护具** |
| 下装 | 黑长裤塞进黑靴，深钢色护膝 + 分段护胫 |
| 刀 | 弧度较小的单刃刀身、波纹刃文、铜色鎺、圆形铁镡带铜边、黑柄深红菱形缠绳；黑漆刀鞘带银色尾端和深红短绳，挂左腰、柄朝前上 |

## 二、设定集清单

| 编号 | 内容 | 源图 | 衍生文件 |
|---|---|---|---|
| A0 | 身份辨识点标注 + 头身比例尺 | 由 A1 生成 | 预览 `identity_callouts.png` |
| A1 | 四向转面 | `sheet_main_c1.png`（母版） | `views/A1_*.png` 透明图、`measure.json` |
| A2 | 游戏机位持刀站姿（朝右） | `sheet_pose_head_c2.png` 左半 | `views/A2_ready_right.png` |
| A3 | 头部与六种表情 | `sheet_pose_head_c2.png` 右半 | — |
| A4 | 素体 | `sheet_main_c1.png` | `views/A4_base_body.png` |
| A5 | 槽位拆解 | `sheet_parts_c1.png` | `sheet_parts_c1_clean.png`（去圈号）、`parts/<槽位>__<部件>.png`、`parts/parts.json` |
| A6 | 色号表 | 取自 A1 正面 | `palette.json` |
| A7 | 标准太刀与标定 | `sheet_weapon_c1.png` | `weapon/*.png`、`weapon/katana.json` |

预览都在 `docs/previews/standard_v1/`：`standard_sheet.jpg`（总图）、`identity_callouts.png`、`parts_slots.jpg`、`palette.png`、`weapon_calibration.png`、`weapon_v6_overlay.jpg`、`game_scale.png`。
重新生成衍生文件：依次运行 `tools/explore/` 下的 `standard_master.py`、`standard_weapon.py`、`standard_parts.py`、`standard_sheet.py`。

未采用：`sheet_main_c2`（手臂多出金属护臂）、`sheet_pose_head_c1`（全身像朝左；D030 已改为 c2）。

## 三、自检结果

| 项 | 结果 |
|---|---|
| A1 四向身高差 / 脚底线差 | 9 px（1.3%）/ 9 px，母版身高约 680 px |
| A6 色号（中值） | 银白发 `#bdbcc0`、挑染 `#602b39`、皮肤 `#e8cabb`、内衬 `#5c1e30`、绷带 `#561e2c`、黑皮 `#1e1d21`、深钢 `#393a40`、靴 `#1a1b1f`；亮部 / 暗部见 `palette.json` |
| A7 实机尺寸（人物 190 px） | 刀身（护手→刀尖）128 px，约 0.67 身高；柄 48 px；握点距护手 11 px。刀身取 V6 全部 139 帧标定的最大值，握点取中位值 |
| A7 与 V6 对位 | 按护手→刀尖贴回 V6 attack1/2/3 帧，柄长与握位与 V6 原画基本吻合 |
| 游戏尺寸 | 正面 / 侧面 / A2 缩到 190 px 后剪影可读，见 `game_scale.png` |

## 四、已知瑕疵（方式乙：保留原图，以文字规格为准）

| 位置 | 瑕疵 | 处理 |
|---|---|---|
| A1 侧面 | 缺护膝护胫 | 以规格为准；以后有参考图编辑工具再在母版上局部修 |
| A1 背面 | 看不到刀鞘 | 同上 |
| A4 素体 | 带了护膝（护具属于"鞋"槽位） | 同上 |
| A3 | 3/4 头像挑染略偏中 | 同上 |
| A5 | 胸前束带画成背带式；刀鞘里带着刀；没有单独的发型件 | 束带以规格为准；空鞘以 A7 为准；发型以 A1 / A3 为准 |
| A5 | 生图多画了圈号 | 已在 `sheet_parts_c1_clean.png` 中抹掉 |
| A7 | 空鞘多画了一个镡 | 已在 `weapon/scabbard_empty.png` 中切掉 |

## 五、增补项（不阻塞 S4）

两次生图都因确认框超时没有生成，下次在 ws1 生图时补：

1. **A8 手部与握法**：正手握、反手握、拔刀握、空握拳（中间留出刀柄通道）、张手掌心、张手手背。用于 S4 第 4 步"去刀补握拳"和手指层。
2. **A5 按槽位重出**：含单独发型件、两道横向胸带、空鞘，不画编号。

增补后以 standard_v1 的追加文件入库，不改动已锁定的文件。
