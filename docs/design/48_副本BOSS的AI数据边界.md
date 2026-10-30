# 48 副本 BOSS 的 AI 数据边界

> 结论：**当前 18 个副本 BOSS，没有任何一个有“有实质内容的原版行为脚本”**。
> 这不是没找到，而是原版本来就没有——它们的行由引擎内置通用 AI + `.mob` 数值驱动。

## 一、先纠正一个层级错误

AI 脚本是**按族共享**的，不是每只怪一份：

```
monster/goblin/ai/action.ai              ← 哥布林全族共用
monster/goblin/ai/destinationselect.ai
monster/goblin/ai/event.ai
monster/goblin/ai/movemethod.ai
```

同目录的 `goblin`、`goblinthrower`、`goblintaskmaster`、`seagab`、`hillgab`、`kinol` 全部吃这一套。

之前按「单只怪目录」查 `.ai`（如 `monster/draconian/mirkius.mob` 旁边），结论是「老版怪没有 AI」——**这一步是错的**。

## 二、但纠正后，内容是空壳

`monster/goblin/ai/` 四个文件反编译后的全部逻辑：

| 文件 | 内容 | 实际作用 |
|---|---|---|
| `action.ai`（22 字节） | `[return] -1` | **不选招**，把选择权交回引擎 |
| `movemethod.ai`（67 字节） | `[target distance] >= 300 → [return] 1`；否则也是 `1` | 恒为 1，等于常量 |
| `destinationselect.ai`（347 字节） | `[target state] 4` / `[hp] %> = 45` / `is target in attack area() 320…` / `400…` | 唯一有真实逻辑的：决定**往哪走** |
| `event.ai`（132 字节） | `[hit] 1` → `party member number()` 判断 | 受击时简单反应 |

也就是说：**这些怪的“选招”不由脚本决定**，脚本只管移动目的地。

## 三、覆盖统计

| 项 | 数量 |
|---|---|
| 副本真正的 BOSS（地图带 `[boss]` 标记） | 18 |
| 全库有 `ai/` 的目录 | 982（绝大多数在 `act8/`、`newmonsters/`） |
| 副本 BOSS 所属族有 `ai/` 的 | **2**：`goblinthrower`、`kinol`（都在 `monster/goblin`） |
| 其中 `action.ai` 有实质选招逻辑的 | **0** |
| 族目录完全没有 `ai/` 的 | **16** |

18 个 BOSS 名单：`masterdogri`、`lakius`、`levileye`、`revileye`、`selion`、`goblinthrower`、`kinol`、`lordoflight`、`kurogaru`、`penril`、`platany`、`keraha`、`vinoshu`、`vinoshu_quest`、`heavenexpeller`、`taubeast`、`zombieghoulgwish`（+ `goblintaskmaster` 等首领）。

## 四、因此这几个方案都不成立

| 方案 | 为什么不成立 |
|---|---|
| 换血到 `newmonsters` 版 mob | 换过去也只有 4 个能映射，且其中 2 个（goblinthrower/kinol）的脚本本来就是空壳 |
| 继续逆 `.ai` 字节码 | 副本 BOSS 没有可用的 `.ai`，解出来也没数据可跑 |
| 按「通用模板再特化」写 AI | 这是自创，不是复刻（使用者明确不接受） |

## 五、能做到的极限（当前实现）

| 数据 | 来源 | 状态 |
|---|---|---|
| 招式集（17 BOSS / 51 招） | `.mob` 的 `[attack motion]` 多值 | ✅ |
| 每招能打多远 | 该招 ANI 的 damage 判定盒 | ✅ |
| 伤害/击退/浮空/击倒/命中音 | 各招 `.atk` | ✅ |
| 选招依据 | **距离落在哪招的判定范围** | ✅（数据驱动，非脚本） |
| 阶段切换 | 血量 < 40% 优先高伤招 + 出手提速 | ⚠️ E-ADAPT（原版阈值写在 `.ai`，无数据） |
| 召唤 | `.mob` 无字段、ANI 无事件 | ❌ 无数据 |

## 六、要看到“真实的原版 AI 行为”，唯一的路是加内容

全库 982 个带 `ai/` 的目录里，只有后期内容有实质脚本。例如 `mirkius`（`newmonsters/realsky/`）：

```
[think] [void]
    number of in attack area() 10000×4  all summon 61523
    [last result] == 0
    [true]  → 技能 4 冷却检查 → [return] 4
    [false] → is target in attack area() 200 200 30 30
                → 技能 2 冷却检查 → [return] 2
```

这类怪**不在任何已装副本里**。要看到它们的行为，必须新增对应副本（act8 / newmonsters 系），而不是替换现有副本的怪。

## 七、方法论教训

1. **资源是按“族”组织的**：先查 `monster/<族>/ai/`，再查单怪目录；
2. **“有文件” ≠ “有内容”**：`action.ai` 只有 `[return] -1` 也算有文件（22 字节）；
3. 下结论前要同时统计**覆盖率**和**内容实质**，否则会得出“有 2 个 BOSS 有 AI”这种误导性结论。
