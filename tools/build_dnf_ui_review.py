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
    ('城镇', '艾尔文防线，人物、锻炉、树屋和招牌的同场效果。', '01_town.png'),
    ('NPC 对话', '林纳斯对话，以及任务和商店入口。', '02_linus.png'),
    ('任务列表', '可接受、进行中、已完成分类；左侧列表和右侧目标、奖励详情。', '03_quest.png'),
    ('商店', '商店与背包并排；原商品格与滚动组件，悬停显示商品价格。', '04_shop.png'),
    ('背包与装备', '通关领奖后的物品、装备位置与属性说明。', '11_reward_equipment.png'),
    ('物品悬停详情', '真实鼠标悬停产生的独立物品详情窗，支持边缘避让。', '05b_inventory_hover.png'),
    ('地下城选择', '原800×600羊皮地图、原地下城卡片、中文难度和冒险按钮。', '06_departure.png'),
    ('战斗', '当前接入的五房试炼战斗，使用原版角色与场景素材。', '09_combat_action.png'),
    ('通关结算', '原评价底图与奖励卡片；实际战斗统计。', '10_result.png'),
    ('翻牌后', '鼠标翻开卡牌后确认回城；重开结算不会重复发奖。', '10b_result_reward.png'),
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
                        'source': 'supplied_client_guide' if filename.startswith('reference_') else 'godot_framebuffer',
                        'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)})
        cards.append(f'''<article><button class="shot" data-title="{html.escape(title)}" aria-label="查看{title}原图">
<img src="screens/{filename}" alt="{title}"></button>
<div class="caption"><h2><span>{index:02}</span> {title}</h2><p>{caption}</p></div></article>''')
    commit = subprocess.run(['git', 'rev-parse', '--short', 'HEAD'], cwd=ROOT,
                            capture_output=True, text=True, check=True).stdout.strip()
    metadata = {'source': 'Godot framebuffer and explicitly labeled original guide references; unchanged PNG bytes',
                'commit': commit, 'screens': records}
    (output/'manifest.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    page = '''<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>当前游戏 · 实机界面评审</title><style>
*{box-sizing:border-box}body{margin:0;background:#111713;color:#e9e2d0;font:15px/1.65 "Microsoft YaHei",sans-serif}
header,main,footer{max-width:1344px;margin:auto;padding:24px}header{padding-top:34px}h1{margin:0;font-size:28px;color:#edcf87}
header p{margin:8px 0;color:#b7bdad}a{color:#e8cc87}main{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,520px),1fr));gap:24px;padding-top:0}
article{background:#1b231d;border:1px solid #45513c;border-radius:8px;overflow:hidden}.shot{display:block;padding:0;width:100%;background:none;border:0;cursor:zoom-in}
.shot img{display:block;width:100%;height:auto;image-rendering:pixelated}.caption{padding:14px 18px}h2{margin:0;font-size:17px}h2 span{color:#9b9e87;margin-right:8px;font-size:13px}
.caption p{color:#bac0ad;font-size:13px;margin:5px 0 0}footer{color:#a5ad99;padding-top:0}dialog{padding:0;background:#111713;color:#eee4c8;border:1px solid #a58b50;max-width:96vw;max-height:96vh}
dialog::backdrop{background:#000d}.toolbar{display:flex;align-items:center;gap:14px;padding:10px 14px;position:sticky;top:0;background:#1b231d;z-index:1}
.toolbar button{font:inherit;color:#edcf87;background:#293427;border:1px solid #6d7756;padding:4px 12px;cursor:pointer}.viewer{overflow:auto;max-width:95vw;max-height:85vh}.viewer img{display:block;image-rendering:pixelated;max-width:none}
</style><header><h1>当前游戏 · 实机界面</h1><p>本次实际运行截图 · 中文界面 · 点击图片查看原始像素，也可切换两倍查看</p>
<p>本轮UI返修：对应版本HUD、底部对话、任务列表、并排商店与背包、悬停详情、地图选图和结算翻牌。末尾两张为原包攻略对照。当前仍需你复核还原程度。</p>
<a href="screenshots.zip" download>下载全部截图</a></header><main>'''+''.join(cards)+'''</main>
<footer>实机截图未修图，原包攻略截图单独标注。原资源与UI配置已核对；尚未取得原客户端同条件实机截图，不能据此宣称像素级一致。</footer>
<dialog id="zoom"><div class="toolbar"><strong id="name"></strong><button id="scale">两倍查看</button><button id="close">关闭</button></div><div class="viewer"><img id="full" alt="游戏实机原图"></div></dialog>
<script>const d=document.querySelector('#zoom'),im=document.querySelector('#full'),s=document.querySelector('#scale');
let doubled=false;document.querySelectorAll('.shot').forEach(b=>b.onclick=()=>{im.onload=()=>{im.style.width=im.naturalWidth+'px'};im.src=b.querySelector('img').src;doubled=false;document.querySelector('#name').textContent=b.dataset.title;s.textContent='两倍查看';d.showModal()});
s.onclick=()=>{doubled=!doubled;im.style.width=(im.naturalWidth*(doubled?2:1))+'px';s.textContent=doubled?'原始像素':'两倍查看'};
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
