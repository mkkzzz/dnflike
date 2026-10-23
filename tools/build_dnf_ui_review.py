"""Arrange unmodified Godot framebuffer captures as a local Chinese review gallery."""
from __future__ import annotations
import argparse
import hashlib
import html
import json
from pathlib import Path
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SCREENS = [
    ('角色选择', '启动先进入原包舞台；创建后选中鬼剑士，点击原开始按钮、双击角色或Enter进入城镇。', '49_character_selected.png'),
    ('创建鬼剑士', '原版建角背景与386×600鬼剑士立绘，固定职业，输入中文角色名创建独立存档。', '47_character_create.png'),
    ('多个独立角色', '角色等级、金币、任务和物品独立保存；可从城镇菜单返回选人。', '50_character_roster.png'),
    ('名字校验', '空名、重名与无效字符会提示；创建失败保留既有角色。', '48_character_name_error.png'),
    ('首次启动', '没有存档时保留空角色位和创建入口；已有单角色存档自动原位显示。', '46_character_empty.png'),
    ('城镇 · 原休闲站姿', '原Rest 176～179帧；城镇隐藏手持武器，与战斗持刀警戒站姿区分。', '23_town_rest.png'),
    ('城镇 · 移动', '使用原Move完整彩色服装图层，城镇无持刀显示；不是SIMPLE白色轮廓。', '24_town_walk.png'),
    ('走路穿帮 · 原像素分层对照', '离线素材对照：同一帧修复前后；181/185走路、105/109跑步。修复裤子后层被身体覆盖，不删帧、不补画。', 'source_locomotion_comparison.png'),
    ('战斗走路 · 第181帧', '真实键盘行走自然到达该相位后暂停截取，检查原先露腿处。', '26_battle_walk_181.png'),
    ('战斗走路 · 第185帧', '另一个原先露腿相位；八相位均保存到同版证据包，动作时钟未改。', '26_battle_walk_185.png'),
    ('数字键直接翻牌', '实机按4翻开第四张卡，不需二次确认；保留返回城镇出口，翻牌不会重复支付。', '25_number_card_flip.png'),
    ('背包 · 统一格子与底栏', '八列六排48格；第六排末格支持实际拖拽与持久化，负重和货币随底板下移。', '21_inventory_six_rows.png'),
    ('购买数量确认', '点击商品先确认数量、单价和总价，确认后扣款；取消保留金币和物品。', '17_purchase_quantity.png'),
    ('技能详细说明', '悬停显示简介、耗蓝、冷却和伤害倍率，按住Shift展开中文说明；数值读取当前战斗表；详情底边紧贴对应技能格。', '20_attached_skill_detail.png'),
    ('快捷物品详情', '物品详情贴在所属快捷格正上方；支持拖拽放入、换位和移回背包。', '19_attached_item_detail.png'),
    ('经验条悬停', '经验进度与原背景槽位对齐；悬停显示当前经验和下一级所需经验。', '13_experience_hover.png'),
    ('地图与难度', '选中框贴合地图卡片；下方原生难度组件可切换普通、冒险、王者，去掉左下房间说明。', '22_attached_difficulty.png'),
    ('商店 · 品质与底栏', '物品框随品质变化；分类条与底板齐边，负重、复活币、点券、决斗点和金币分别对齐。', '04_shop.png'),
    ('稀有武器详情', '品质标题、类型、等级/职业、重量、属性与购买价格分区；原生细线划分层级。', '04b_shop_detail.png'),
    ('背包 · 正确武器槽', '已装备武器落在原图武器槽，不再放进首饰区；背包显示尚未穿戴的装备，关闭按钮避开页签。', '11_reward_equipment.png'),
    ('背包 · 消耗品', '药剂品质框与数量位于格内，分类条与物品底板对齐。', '05c_inventory_consumables.png'),
    ('普通武器详情', '白色普通、紫色稀有的名称和边框区分；已装备状态、条件和属性分层；不再写装备操作说明。', '05b_inventory_hover.png'),
    ('城镇 · 固定1080p', '1920×1080实机：保持4:3原像素构图，中文文字按显示密度绘制；城镇草地和前景地面已扩展为可走区域。', '01_town.png'),
    ('生命值悬停', '血球不常驻百分比；真实鼠标悬停显示当前生命值/上限。快捷栏图标保持在原生格框内。', '01d_hp_hover.png'),
    ('魔法值悬停', '蓝球不常驻百分比；真实鼠标悬停显示当前魔法值/上限。', '01e_mp_hover.png'),
    ('NPC 对话', '原包林纳斯186×226上半身大立绘；底部对话板，正文与选项留出人物空间。', '02_linus.png'),
    ('任务列表', '可接受、进行中、已完成分类；左侧列表和右侧目标、奖励详情。', '03_quest.png'),
    ('地下城选择', '原800×600羊皮地图、原地下城卡片、中文难度和冒险按钮。', '06_departure.png'),
    ('战斗', '当前接入的五房试炼战斗，使用原版角色与场景素材。', '09_combat_action.png'),
    ('通关结算', '原评价底图与奖励卡片；实际战斗统计。', '10_result.png'),
    ('翻牌后', '鼠标直接翻开卡牌，翻开后可回城；重开结算不会重复发奖。', '10b_result_reward.png'),
    ('原包攻略对照 · 背包与HUD', '来自原包附带攻略，角色与场景不同，仅用于核对界面家族、材质和构图。', 'reference_hud_inventory.png'),
    ('原包攻略对照 · 选图', '来自同一攻略的原游戏选图；与当前实机截图分开标注。', 'reference_dungeon_map.png'),
]


def build(source: Path, output: Path) -> Path:
    output = output.resolve()
    if not output.is_relative_to((ROOT/'temp').resolve()):
        raise ValueError('Review output must stay inside temp/')
    images = output/'screens'
    images.mkdir(parents=True, exist_ok=True)
    records, cards = [], []
    for index, (title, caption, filename) in enumerate(SCREENS, 1):
        path = source/filename
        data = path.read_bytes()
        if data[:8] != b'\x89PNG\r\n\x1a\n':raise ValueError('Not a framebuffer PNG: ' + filename)
        target = images/filename
        shutil.copyfile(path, target)
        records.append({'title': title, 'file': 'screens/'+filename,
                        'source': 'supplied_client_guide' if filename.startswith('reference_') else 'source_pixel_comparison' if filename.startswith('source_') else 'godot_framebuffer',
                        'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)})
        cards.append(f'''<article><button class="shot" data-title="{html.escape(title)}" aria-label="查看{title}原图">
<img src="screens/{filename}" alt="{title}"></button>
<div class="caption"><h2><span>{index:02}</span> {title}</h2><p>{caption}</p></div></article>''')
    commit = subprocess.run(['git', 'rev-parse', '--short', 'HEAD'], cwd=ROOT,
                            capture_output=True, text=True, check=True).stdout.strip()
    metadata = {'source': 'Godot framebuffer and explicitly labeled source-pixel comparison / original guide references; unchanged PNG bytes',
                'commit': commit, 'screens': records}
    (output/'manifest.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    page = '''<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>当前游戏 · 实机界面评审</title><style>
*{box-sizing:border-box}body{margin:0;background:#111713;color:#e9e2d0;font:15px/1.65 "Microsoft YaHei",sans-serif}
header,main,footer{max-width:1344px;margin:auto;padding:24px}header{padding-top:34px}h1{margin:0;font-size:28px;color:#edcf87}
header p{margin:8px 0;color:#b7bdad}a{color:#e8cc87}main{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,520px),1fr));gap:24px;padding-top:0}
article{background:#1b231d;border:1px solid #45513c;border-radius:8px;overflow:hidden}.shot{display:block;padding:0;width:100%;background:none;border:0;cursor:zoom-in}
.shot img{display:block;width:100%;height:auto;image-rendering:auto}.caption{padding:14px 18px}h2{margin:0;font-size:17px}h2 span{color:#9b9e87;margin-right:8px;font-size:13px}
.caption p{color:#bac0ad;font-size:13px;margin:5px 0 0}footer{color:#a5ad99;padding-top:0}dialog{padding:0;background:#111713;color:#eee4c8;border:1px solid #a58b50;max-width:96vw;max-height:96vh}
dialog::backdrop{background:#000d}.toolbar{display:flex;align-items:center;gap:14px;padding:10px 14px;position:sticky;top:0;background:#1b231d;z-index:1}
.toolbar button{font:inherit;color:#edcf87;background:#293427;border:1px solid #6d7756;padding:4px 12px;cursor:pointer}.viewer{overflow:auto;max-width:95vw;max-height:85vh}.viewer img{display:block;image-rendering:auto;max-width:none}
</style><header><h1>当前游戏 · 选人与创建鬼剑士</h1><p>本次实际运行截图 · 全中文 · 点开适合屏幕，切换原始像素后可横向滑动查看细节</p>
<p>本轮新增：原版舞台角色选择、鬼剑士大立绘建角、中文取名与独立角色存档；城镇、副本、结算、背包等完整流程保留。素材对照单独标注，末两张为原包攻略，其余为Godot实机截图。</p>
<a href="screenshots.zip" download>下载全部截图</a></header><main>'''+''.join(cards)+'''</main>
<footer>实机截图未修图，离线源像素对照和原包攻略单独标注。原资源与UI配置已核对；尚未取得原客户端同条件实机截图，不能据此宣称像素级一致。</footer>
<dialog id="zoom"><div class="toolbar"><strong id="name"></strong><button id="scale">原始像素</button><button id="close">关闭</button></div><div class="viewer"><img id="full" alt="游戏实机原图"></div></dialog>
<script>const d=document.querySelector('#zoom'),im=document.querySelector('#full'),s=document.querySelector('#scale');
let native=false;const fit=()=>Math.min(im.naturalWidth,innerWidth*.95);document.querySelectorAll('.shot').forEach(b=>b.onclick=()=>{im.onload=()=>{im.style.width=fit()+'px'};im.src=b.querySelector('img').src;native=false;document.querySelector('#name').textContent=b.dataset.title;s.textContent='原始像素';d.showModal()});
s.onclick=()=>{native=!native;im.style.width=(native?im.naturalWidth:fit())+'px';s.textContent=native?'适合屏幕':'原始像素'};
document.querySelector('#close').onclick=()=>d.close();d.onclick=e=>{if(e.target===d)d.close()};</script></html>'''
    (output/'index.html').write_text(page, encoding='utf-8')
    with zipfile.ZipFile(output/'screenshots.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
        for item in records:archive.write(output/item['file'], Path(item['file']).name)
    return output/'index.html'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT/'temp/loop_review')
    parser.add_argument('--output', type=Path, default=ROOT/'temp/loop_ui_review')
    args = parser.parse_args()
    print(build(args.source.resolve(), args.output))
