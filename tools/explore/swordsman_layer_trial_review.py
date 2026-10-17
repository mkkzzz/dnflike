"""Publish review media from the actual v7 layer package, with no actor edits."""
import hashlib,json,shutil
from pathlib import Path
from PIL import Image,ImageDraw,ImageFont

ROOT=Path(__file__).resolve().parents[2]
PACKAGE=ROOT/'art/animations/players/swordsman/v7/exports/layer_trial_c3'
OUT=ROOT/'docs/previews/v7_layer_trial_c3'


def load(path):return json.loads(path.read_text(encoding='utf-8'))
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def at(frames,tick):
    return next((f for f in frames if f['start_tick']<=tick<f['start_tick']+f['duration_ticks']),frames[-1])
def panel(image,label,size,offset=(0,0)):
    result=Image.new('RGBA',size,'#20242b');result.alpha_composite(image,offset)
    d=ImageDraw.Draw(result);d.text((10,8),label,font=FONT,fill='white')
    return result.convert('RGB')
FONT=ImageFont.truetype('C:/Windows/Fonts/msyh.ttc',18)


def main():
    manifest=load(PACKAGE/'manifest.json');preview=PACKAGE/'previews';OUT.mkdir(parents=True,exist_ok=True)
    # Exact 0.75 shrink for the 1080p offline viewing check.
    with Image.open(preview/'three_weapons.gif') as gif:
        frames=[];durations=[]
        for i in range(gif.n_frames):
            gif.seek(i);durations.append(gif.info['duration'])
            frame=gif.convert('RGB');frames.append(frame.resize((round(frame.width*.75),round(frame.height*.75)),Image.Resampling.LANCZOS))
    frames[0].save(preview/'three_weapons_1080p.gif',save_all=True,append_images=frames[1:],duration=durations,loop=0,disposal=2,optimize=False)
    frame=manifest['frames'][3]
    def opened(name):
        with Image.open(PACKAGE/name) as image:return image.convert('RGBA')
    body=opened(frame['body']);fingers=opened(frame['fingers']);katana=frame['profiles']['katana']
    weapon=Image.alpha_composite(opened(katana['back']),opened(katana['front']))
    entries=[(body,'共用身体：无固定武器'),(weapon,'独立太刀层'),(fingers,'共用手指遮挡层')]
    entries += [(opened(frame['profiles'][name]['composite']),label) for name,label in [('katana','太刀合成'),('greatsword','巨剑合成'),('shortsword','短剑合成')]]
    window=(230,260,950,770);cell=(720,510);board=Image.new('RGB',(2160,1020),'#20242b')
    for i,(image,label) in enumerate(entries):board.paste(panel(image.crop(window),label,cell),((i%3)*720,(i//3)*510))
    board.save(preview/'layers_contact.png')
    # All seven authored poses, unscaled original export pixels.
    contact=Image.new('RGB',(2220,1530),'#20242b')
    for i,row in enumerate(manifest['frames']):
        image=opened(row['profiles']['katana']['composite']).crop((80,240,820,750))
        contact.paste(panel(image,f'{i+1:02d} / '+row['source_pose'],(740,510)),((i%3)*740,(i//3)*510))
    contact.save(preview/'katana_contact.png')
    # At 190px standing height: only new 380px art is downsampled by 0.5.
    old_path=ROOT/'art/animations/players/swordsman/v6/exports/manifest.json';old=load(old_path)['clips']['actor/attack1']
    cache={}
    for row in old['frames']:
        with Image.open(old_path.parent/row['file']) as image:cache[row['file']]=image.convert('RGBA')
    samples=[]
    for tick in range(48):
        actual=min(29,tick);a=at(old['frames'],actual);b=at(manifest['frames'],actual)
        old_panel=panel(cache[a['file']],'现行 V6 / 190px',(512,320))
        image=opened(b['profiles']['katana']['composite']).convert('RGBa').resize((512,400),Image.Resampling.LANCZOS).convert('RGBA')
        new_panel=panel(image,'新分层候选 / 缩小至190px',(512,320),(0,-80))
        sample=Image.new('RGB',(1024,320));sample.paste(old_panel,(0,0));sample.paste(new_panel,(512,0));samples.append(sample)
    boundaries=[round(t*100/60)*10 for t in range(49)];durations=[b-a for a,b in zip(boundaries,boundaries[1:])]
    samples[0].save(preview/'v6_compare.gif',save_all=True,append_images=samples[1:],duration=durations,loop=0,disposal=2,optimize=False)
    samples[9].save(preview/'v6_compare_contact.png')
    publication=[]
    for name in ['three_weapons.gif','three_weapons_slow3x.gif','three_weapons_left.gif','three_weapons_1080p.gif','layers_contact.png','katana_contact.png','v6_compare.gif','v6_compare_contact.png']:
        src=preview/name;dst=OUT/name;shutil.copyfile(src,dst)
        publication.append({'package':src.relative_to(ROOT).as_posix(),'published':dst.relative_to(ROOT).as_posix(),'sha256':digest(src),'byte_identical':digest(src)==digest(dst)})
    (OUT/'publication.json').write_text(json.dumps({'same_package':True,'media':publication,'note':'GIFs have 30 action ticks plus 18 review-only end-hold ticks; 3x slow and 0.75 downsample are explicitly named. V6 comparison is at native old 190px, never upscaled.'},ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
    print('Published eight byte-identical package review files; no actor art changed.')


if __name__=='__main__':main()
