extends RefCounted
## 场景画面基准：城镇、副本、战斗共用这一份，禁止各自再加偏移或缩放。
## 依据原版数据（tools/export_dnf_map.py）：TIL 地砖 224×480、背景层顶端 -80、通行格 30×12。
## 美术坐标系纵向 -80…480；把美术顶端 -80 对到画布顶端 0，得到 ART_DY=80，美术底落在 560，
## 正好盖住 HUD 底图（800×92，贴 508）的镂空行，画面底部不需要任何补图。
## map 坐标（角色、门、物件锚点）比美术坐标多 120（导出器的 screen_y_offset），故 MAP_DY=200。
const WIDTH := 800
const HEIGHT := 600
const ART_TOP := -80
const ART_BOTTOM := 480
const ART_DY := 80
const MAP_TO_ART := 120
const MAP_DY := MAP_TO_ART + ART_DY
const HUD_TOP := 508
const HUD_HEIGHT := 92
