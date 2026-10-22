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
    ('物品格修正 · 商店与背包', '统一原生32像素网格，完整保留上下左右边框；28像素图标居中，空格与物品格共用边线。', '04_shop.png'),
    ('物品格修正 · 装备', '两件装备在相邻格内，边框连续；物品按钮不再叠加通用底板。', '11_reward_equipment.png'),
    ('物品格修正 · 消耗品', '恢复药剂和数量位于同一格内；分类、购买与数量数据仍走实际游戏流程。', '05c_inventory_consumables.png'),
    ('物品悬停详情', '悬停不遮盖图标，原Global细金边详情框继续使用；边缘自动避让。', '05b_inventory_hover.png'),
    ('城镇 · 两倍窗口', '1600×1200实机：原素材整数缩放，动态文字按窗口分辨率绘制，HUD透明区下方补齐原地面。', '01_town.png'),
    ('城镇 · 原始大小', '800×600原始大小对照。原素材没有更高分辨率细节；菜单可切换原始大小和两倍大小。', '01c_native_1x.png'),
    ('NPC 对话', '原包林纳斯186×226上半身大立绘；底部对话板，正文与选项留出人物空间。', '02_linus.png'),
    ('任务列表', '可接受、进行中、已完成分类；左侧列表和右侧目标、奖励详情。', '03_quest.png'),
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
.shot img{display:block;width:100%;height:auto;image-rendering:auto}.caption{padding:14px 18px}h2{margin:0;font-size:17px}h2 span{color:#9b9e87;margin-right:8px;font-size:13px}
.caption p{color:#bac0ad;font-size:13px;margin:5px 0 0}footer{color:#a5ad99;padding-top:0}dialog{padding:0;background:#111713;color:#eee4c8;border:1px solid #a58b50;max-width:96vw;max-height:96vh}
dialog::backdrop{background:#000d}.toolbar{display:flex;align-items:center;gap:14px;padding:10px 14px;position:sticky;top:0;background:#1b231d;z-index:1}
.toolbar button{font:inherit;color:#edcf87;background:#293427;border:1px solid #6d7756;padding:4px 12px;cursor:pointer}.viewer{overflow:auto;max-width:95vw;max-height:85vh}.viewer img{display:block;image-rendering:auto;max-width:none}
</style><header><h1>当前游戏 · 物品格定位修正</h1><p>本次实际运行截图 · 全中文 · 点开适合屏幕，切换原始像素后可横向滑动查看细节</p>
<p>前四张为本轮商店、装备、消耗品与悬停实拍：纠正原网格裁切起点和32像素间距，图标居中，移除悬停按钮底板。后续保留城镇、对白、选图和结算。场景保留原像素，文字按窗口分辨率绘制；末尾为原包攻略。</p>
<a href="screenshots.zip" download>下载全部截图</a></header><main>'''+''.join(cards)+'''</main>
<footer>实机截图未修图，原包攻略截图单独标注。原资源与UI配置已核对；尚未取得原客户端同条件实机截图，不能据此宣称像素级一致。</footer>
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
