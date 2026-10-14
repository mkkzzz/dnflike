# Demo v3 无武器身体动画

本目录保留内置 `image_gen.imagegen` 生成的透明源图、原始提示词、逐帧握点校准图与动画预览。所有主角身体图都不包含剑、刀柄、剑鞘；武器由独立 `WeaponRig` 渲染，后续换装备可以只更换武器 profile。

## 本轮完成

| 动作 | 帧数 | 来源与阶段 |
| --- | ---: | --- |
| walk / run | 各 8 | 新绘步态；walk 包含窄腿 passing 姿态，run 包含压缩与腾空姿态 |
| attack1 / attack2 / attack3 | 各 8 | 前摇 0–2，出手 3–4，收势 5–7；横斩、反撩、重劈分别绘制 |
| upper | 8 | 蹲伏蓄力、上挑、腾空、落下收势 |
| air_attack / dash_attack | 各 8 | 专用空中下劈与奔跑切入，带真实不同身体与衣摆关键帧 |
| rage_slash | 16 | 复用反撩与重劈的两次连续攻击，两个 segments 分别声明命中姿态 |
| thrust | 15 | 三段前伸攻击；明确复用前伸身体姿态，每段有独立时序/握点 |
| idle / guard / jump / air / back_dash / hit / down / getup / blood_rage / quick_draw | 1–8 | 基础姿势去武器后复用；quick_draw 使用新的完整横斩 8 帧 |

八个核心动作（walk、run、三连、upper、air_attack、dash_attack）各有 8 个不同的实际源姿势；未使用图片交叉淡入或重复拷贝来填充核心动作。20 个运行时动作总计使用 73 个独立身体源姿势。基础动作的保持帧及技能的有限姿势复用在 manifest 的 `pose_note` 与 `source_poses` 中记录。

## 烘焙与挂点约定

运行 `tools/bake_body_v3.py` 可重新生成 `game/assets/actors_v3/player/*.png` 和 `game/assets/actors_v3/manifest.json`。需要 Pillow、NumPy；源图无需联网重新生成。

每个源 sheet 按同一骨架比例缩放到约 190 px 站姿，整个 sheet 不对单帧单独缩放。所有动作使用同一个 320×248 帧画布和脚底 root `(144, 230)`。run/air 的腾空帧使用审核过的虚拟地面基线，避免每帧追随最低鞋底造成上下锚点跳动。

`sockets` 与帧数严格等长，每帧包含：

- `hand`: 相对脚底 root 的未翻转局部像素坐标；对准空手握拳中心。
- `angle`: 从向右到剑尖方向的角度，Godot y 轴向下。
- `layer`: `front` / `back`，控制武器在身体前后的遮挡。
- `source_pose`: 明确的源 sheet 与 cell 索引。

每个攻击声明 `phase_frames`，多段技能额外声明 `segments`。运行时应使用该阶段元数据，让真正的攻击判定对应身体出手帧。未来装备只读取武器 profile 和握点，不应把武器重新画回身体 PNG。

## 审核文件

- `generation.json`：六张最终源图的完整提示词、引用图与内置工具 provenance。
- `bake_report.json`：88 个源主体的像素包围盒、source root/hand 校准值、尺度与动作帧数校验。
- `calibration_*.jpg`：原图坐标审核；绿十字是 root，黄圈是握点，蓝线是刀方向。
- `review_*.jpg`：最终帧画布的握点与方向审核。
- 核心动作 `.gif`：身体连续帧预览，武器与特效由运行时添加。

烘焙会验证每个源图的独立主体数、透明背景、全身体未被帧画布裁切、每帧握点邻域接触身体、socket/duration/source_pose 数量一致、phase 索引合法，以及八个核心动作各有 8 个不同像素帧。以上属于素材管线校验；完整战斗判定与实机体验需由 Godot 集成验证。

已知素材边界：基础 guard/air 仍为保持姿势，基础 idle 为两帧；thrust 的三次刺击复用前伸身体姿态。武器 layer 与握点已完整拆分，后续可单独补专用刺击或更丰富呼吸/防御帧，无需重做武器管线。
