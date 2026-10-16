"""Rebuild diagnostic comparison from original pixels, never modify actor assets."""
import importlib.util
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT=Path(__file__).resolve().parents[2]
REVIEW=ROOT/'art/animations/players/swordsman/v7/reviews/2026-10-17_proportions'
OUT=ROOT/'docs/previews/v7_proportions_2026-10-17'


def main():
    report=json.loads((REVIEW/'report.json').read_text(encoding='utf-8'))
    audit=json.loads((REVIEW/'audit.json').read_text(encoding='utf-8'))
    config_path=ROOT/audit['config']
    config=json.loads(config_path.read_text(encoding='utf-8'))
    spec=importlib.util.spec_from_file_location('pilot_audit_helpers',ROOT/'tools/explore/standard_actions_pilot.py')
    pilot=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pilot)
    sources=pilot.load_sources(config,config_path.parent)
    OUT.mkdir(parents=True,exist_ok=True)
    board=Image.new('RGBA',(2000,680),'#20242b')
    font=ImageFont.truetype('C:/Windows/Fonts/msyh.ttc',24)
    small=ImageFont.truetype('C:/Windows/Fonts/msyh.ttc',20)
    draw=ImageDraw.Draw(board)
    draw.text((16,10),'v7 头部显示尺度复核：同一站立等效身高 380 px',font=font,fill='white')
    draw.text((16,47),'直接从原生源图向下取样，显示口径是旧 190 px 的两倍；不是把旧导出图放大，也不是正式新资源。',font=small,fill='#c7cbd2')
    ground=540
    draw.line((0,ground,2000,ground),fill='#7e858d',width=1)
    with Image.open(ROOT/'art/concepts/characters/players/swordsman/standard_v1/sheet_main_c1.png') as original:
        cut=original.convert('RGBA').crop((50,51,310,732))
    scale=380/681
    cut=cut.resize((round(cut.width*scale),380),Image.Resampling.LANCZOS)
    board.alpha_composite(cut,(250-cut.width//2,ground-380))
    expected=report['reference_visible_head_ratio']*380
    draw.text((20,89),'锁定原画 A1（站姿）',font=font,fill='white')
    draw.text((20,125),f'含发头部约 {expected:.1f} px',font=small,fill='#8ee1a3')
    picks=[('attack1','普攻准备帧'),('run','奔跑接触帧'),('jump_demo','跳跃恢复帧')]
    sampling=[]
    for index,((clip_name,label),measurement,annotation) in enumerate(zip(picks,report['measurements'],audit['poses']),1):
        clip=config['clips'][clip_name]
        pose=next(p for p in clip['poses'] if p['id']==annotation['pose_id'])
        im,record=pilot.export_pose(pose,sources[pose['source']],(1024,800),(448,720),380,clip['root_mode'])
        panel=Image.new('RGBA',(500,390),'#20242b')
        panel.alpha_composite(im,(-198,ground-720-150))
        board.alpha_composite(panel,(index*500,150))
        draw.text((index*500+18,89),'v7 '+label,font=font,fill='white')
        draw.text((index*500+18,125),f'头部约 {measurement["head_output_px"]*2:.1f} px / 偏大约 {measurement["relative_error"]:.0%}',font=small,fill='#ffa8a0')
        top=ground+(annotation['head']['hair_top'][1]-pose['root'][1])*record['scale']
        chin=ground+(annotation['head']['chin'][1]-pose['root'][1])*record['scale']
        bar_x=index*500+470
        draw.line((bar_x,top,bar_x,chin),fill='#ff8c88',width=3)
        draw.line((bar_x-14,top,bar_x-14,top+expected),fill='#8ee1a3',width=3)
        sampling.append({'pose_id':pose['id'],'source_sampling_scale':record['scale']})
    draw.text((16,564),'绿色尺：标准头部包络；红色尺：当前 v7。测量是发顶到下巴，不用蹲姿/收腿后的身高算头身比。',font=small,fill='#d5d9df')
    draw.text((16,600),'结论仅覆盖显示尺度：站立身高估值尚未验证；不能由此声称全部源图骨架都变了，或把整图缩小就当作修好。',font=small,fill='#d5d9df')
    draw.text((16,638),'人工标点误差约 ±3 源像素；旧图与现行 V6 均未被修改。',font=small,fill='#adb4be')
    # The initial PNG was an actual generator reference for c3; preserve it.
    board.convert('RGB').save(OUT/'measurement_comparison_refined.png')
    # The reset preview reads the actual new export package; it is not a
    # separately redrawn or resized replacement for the delivered sprite.
    package=ROOT/'art/animations/players/swordsman/v7/exports/proportion_reset_c3_pair_c1'
    if (package/'manifest.json').exists():
        reset=json.loads((package/'manifest.json').read_text(encoding='utf-8'))
        compare=Image.new('RGBA',(1500,680),'#20242b')
        d=ImageDraw.Draw(compare)
        d.text((16,10),'比例重置 c3 小样：标准原画 / 同图直立基准 / 持刀准备姿态',font=font,fill='white')
        d.text((16,47),'同一 380 px 站立尺度；只缩小源图；下蹲不会被拉回与站姿同高。',font=small,fill='#c7cbd2')
        compare.alpha_composite(cut,(250-cut.width//2,ground-380))
        d.text((18,89),'锁定 A1',font=font,fill='white')
        d.text((18,125),f'头部约 {expected:.1f} px',font=small,fill='#8ee1a3')
        for column,name in enumerate(['neutral','ready'],1):
            frame=reset['clips'][name]['frames'][0]
            with Image.open(package/frame['file']) as sprite:
                panel=Image.new('RGBA',(500,470),'#20242b')
                panel.alpha_composite(sprite.convert('RGBA'),(-198,ground-720-70))
            compare.alpha_composite(panel,(column*500,70))
            metric=next(row for row in reset['proportion_gate']['measurements'] if row['pose_id']==frame['source_pose'])
            d.text((column*500+18,89),'c3 '+('直立基准' if name=='neutral' else '准备姿态'),font=font,fill='white')
            d.text((column*500+18,125),f'头部约 {metric["head_output_px"]:.1f} px / 差异 {metric["relative_error"]:+.1%}',font=small,fill='#8ee1a3')
        d.line((0,ground,1500,ground),fill='#7e858d',width=1)
        d.text((16,565),'仅两个静态姿态，头部尺度数值检查通过；身份、细节、完整动作和实机尚未通过。',font=small,fill='#d5d9df')
        d.text((16,602),'已知细节：直立图保留了入鞘刀柄，空鞘/武器分层后续仍需修正。',font=small,fill='#d5d9df')
        d.text((16,639),'展示来自同一导出包；原始锁定原画、c2 PNG 和现行 V6 均未覆盖。',font=small,fill='#adb4be')
        compare.convert('RGB').save(OUT/'c3_reference_compare.png')
    assert scale<=1 and all(item['source_sampling_scale']<=1 for item in sampling)
    print(json.dumps({'comparison':str(OUT/'measurement_comparison_refined.png'),'source_scales':sampling,'upscaled':False},ensure_ascii=False))


if __name__=='__main__':
    main()
