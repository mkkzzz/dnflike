# ws2 任务：任务系统全套实装（全量）

> 移交方：ws1（2026-10-28）。负责人：ws2（只有该机有原版客户端环境）。
> 关联数据与工具：`game_dnf/data/quest_catalog.json`、`tools/build_dnf_quest_catalog.py`、`tools/check_dnf_quests.py`。
> 运行侧现状：`game_dnf/data/quests.json` 已实装 12 条（11 条有原版源文件），流程与回归（`QUEST_TEST` 45 项）已由 ws2 自己交付，可直接复用。

## 一、背景与现状

ws1 已把原版 **3716 个 `.qst`** 全量解析成总账 `data/quest_catalog.json`（解析失败 0），每条含：路径、目录、品级、等级区间、目标类型、发布/交付 NPC 索引、职业限制、奖励、名称引用、是否已实装。

| 维度 | 现状 |
|---|---|
| 总量 | 3716 |
| 剧情主线 `[epic]` | 941（**当前已实装 11**） |
| 其他品级 | urgent 1276、achievement 510、common unique 420、title 180、daily 140、training 125、normaly repeat 117 |
| 目标类型 | seeking 1176、condition under clear 944、hunt enemy 697、meet npc 447、hunt monster 172、clear map 71… |
| 已实装分布 | elvengard 4、handonmyre 4、common 3（都在 epic_1~epic_5 那条主线上） |
| 待中文化引用 | **1397** 个唯一 `name_ref`（`string:<下标>`） |

## 二、阻塞项：任务文本没有中文源

当前资源库的 `pvf_config.sqlite` 由 **相邻 `111Script.pvf` 备份**建立，其中 `stringtable.bin` 是**键名表**：`[name]` 解出来是 `name_25144` 这种键，不是文本。实测抽样 858 条：中文 0、韩文 9、其余为路径/键名。

T0 凭证（`docs/design/26_DNF原版拆解_证据与版本.md`）记录了四份 PVF，只有 111 备份建过库：

| 角色 | 字节数 | SHA256 前段 | 建库 |
|---|---|---|---|
| 客户端根目录 `Script.pvf` | 183,230,422 | `3c0e8050…` | 否 |
| `ImagePacks2/Script.pvf` | 202,396,005 | `3893d5d1…` | 否 |
| `Video/Script.pvf` | 182,490,884 | `cfea184b…` | 否 |
| 相邻 `111Script.pvf` | 202,404,709 | `f4885045…` | 是（当前库） |

客户端实际加载哪一份尚未锁定；中文串表最可能在**根目录那份**（客户端正常启动读取的）。

## 三、要做的事

1. **取中文串表**：在客户端环境导出根目录 `Script.pvf` 的 `stringtable.bin`（约 15 MB，也可直接发布整份 pvf），上传到资源 Release 并在交接日志登记哈希。
2. **出中文文本表**：按下标 join `quest_catalog.json` 的 `name_ref`，产出 `data/quest_text_zh.json`（`string:25144 → 中文名/描述`）；同一张表同时解决技能名、道具名、NPC 名。
3. **校验语言源**：用已实装的 12 条对照——`epic_1_lorien_1` 应为“林纳斯大叔”、`epic_1_lorien_2` 应为“冒险开始”、`epic_1_lorien_3` 应为“噪音公害”。对不上就改试 `ImagePacks2` 与 `Video` 那两份。
4. **按章节接入**：优先 `[epic]` 941 条，按 `epic_<章>_<区域>_<序号>` 顺序推进；每章接入后跑 `python tools/check_dnf_quests.py` 确认进度上升、无回退。
5. **NPC 与地图前置**：qst 里的 `[npc index]` / `[complete npc index]` 是数字索引，接入前要映射到 `quests.json` 的 NPC 名；缺失的 NPC 与地图同步补齐。
6. **其他品级**：`urgent`（1331，重复/紧急）、`title`（228，称号）、`job`/`epicjob`（243，转职）属独立子系统，需单独设计，不并入主线批次。

## 四、交付与验收

- 每次批次交付：`data/quests.json` 新增任务 + `data/quest_catalog.json` 的 `implemented` 同步 + `check_dnf_quests.py` 进度数字。
- 验收：`tools/run_dnf_loop.ps1 -Test` 全绿（当前基线 348 项），且 `check_dnf_quests.py` 报告 `总账与已实装任务一致`。
- 进度口径：以 `check_dnf_quests.py` 打印的 `epic x / 941` 与各目录实装数作为唯一进度来源。

## 五、ws1 已提供

| 文件 | 作用 |
|---|---|
| `game_dnf/data/quest_catalog.json` | 3716 条总账（grade/等级/类型/NPC/奖励/name_ref/已实装标记） |
| `tools/build_dnf_quest_catalog.py` | 重跑总账（换库或加新 pvf 后执行） |
| `tools/check_dnf_quests.py` | 一致性校验 + 进度打印 |
| `game_dnf/data/quests.json` | 已实装 12 条，格式可直接扩写 |

## 六、风险

- 若根目录那份 pvf 也不是中文，需回到客户端逐份验证（不要仅凭文件名判定，见 26 文档）。
- 任务描述文本（`condition message` / `solve message`）与名称同源，必须一起解决，否则任务详情页会是空或键名。
- 全量接入会显著放大 `quests.json` 体积与加载时间，接入前先确认运行时按章节分片加载。
