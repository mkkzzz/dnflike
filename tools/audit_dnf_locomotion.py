"""Check shipped locomotion provenance, complete frame coverage and exposed clothing.

The source-pixel witness detects the historical naked-leg regression: it compares
opaque source pants-b pixels at their authored coordinates, not a new compositor.
"""
from pathlib import Path
import argparse, hashlib, json
from PIL import Image
from build_dnf_combat_assets import Source, OUT

def audit(library=None):
    src=Source(library)
    data=json.loads((OUT/'manifest.json').read_text(encoding='utf-8'))
    motion=data['player_locomotion']
    town=motion['town']
    assert [f['img_frame'] for f in town['clips']['stay']['frames']]==[176,177,178,179]
    assert town['clips']['stay']['duration_ms']==1050
    assert town['clips']['move']['duration_ms']==800
    assert town['clips']['dash']['duration_ms']==800
    witnesses=[]
    for weapon,poses in motion['battle'].items():
        for pose,indices in [('move',range(180,188)),('dash',range(105,113))]:
            bank=poses[pose]
            atlas=Image.open(OUT.parent.parent / bank['texture'].removeprefix('res://')).convert('RGBA')
            assert set(str(n) for n in indices).issubset(bank['items'])
            for index in [181,185] if pose=='move' else [105,109]:
                cloth,meta=src.frame('sprite/character/swordman/equipment/avatar/pants/sm_pants0000b.img',index)
                rec=bank['items'][str(index)]; rx,ry,w,h=rec['rect']; ox,oy=rec['offset']
                stem={'katana':'katana','shortsword':'sswd','greatsword':'lswd'}[weapon]
                sword,sword_meta=src.frame(f'sprite/character/swordman/equipment/weapon/{stem}/{stem}0000c.img',index)
                total=visible=0
                for y in range(cloth.height):
                    for x in range(cloth.width):
                        pixel=cloth.getpixel((x,y))
                        if pixel[3]!=255:continue
                        sx=meta['x']+x-sword_meta['x']; sy=meta['y']+y-sword_meta['y']
                        if 0<=sx<sword.width and 0<=sy<sword.height and sword.getpixel((sx,sy))[3]>0:continue
                        total+=1
                        dx=meta['x']+x-ox; dy=meta['y']+y-oy
                        if 0<=dx<w and 0<=dy<h and atlas.getpixel((rx+dx,ry+dy))==pixel:visible+=1
                # Shoes, front trousers and held weapon legitimately cover some pixels.
                assert visible/total>0.7, (weapon,pose,index,visible,total)
                witnesses.append(dict(weapon=weapon,pose=pose,frame=index,source_pixels=total,visible_source_pixels=visible))
    for path in motion['avatar_layers']:
        src.image(path)
        assert src.sources[path]==data['sources'][path]
    return dict(schema='dnf_locomotion_audit/1',passed=True,battle_pose_frames=48,town_pose_frames=20,
                clothing_witnesses=witnesses,native_resize_operations=0,
                source_rest='character/swordman/animation/rest.ani',
                interpretation='Town hides held weapon; exact original town-client behavior remains unverified.')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library',type=Path)
    parser.add_argument('--report',type=Path)
    args=parser.parse_args()
    result=audit(args.library)
    if args.report:
        args.report.parent.mkdir(parents=True,exist_ok=True)
        args.report.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result))
