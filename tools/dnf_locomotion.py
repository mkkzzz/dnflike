"""Source-only locomotion banks. Cover both leg partitions after the skin layer.

No frame removal, resizing, skin paint-over or changed ANI clock. Only locomotion
gets a corrected bank; existing attacks keep their established composition.
"""
from PIL import Image

AVATAR = [
    'skin/sm_body0000.img',
    'pants/sm_pants0000b.img', 'shoes/sm_shoes0000b.img',
    'pants/sm_pants0000a.img', 'shoes/sm_shoes0000a.img',
    'coat/sm_coat0000a.img', 'hair/sm_hair0000a.img',
]
WEAPONS = {'shortsword':'sswd', 'katana':'katana', 'greatsword':'lswd'}
MOTION_DIR = 'character/swordman/animation/'

def compose(src, paths, index):
    layers = []
    for path in paths:
        image, meta = src.frame(path, index)
        box = image.getbbox()
        if box:
            layers.append((image.crop(box), meta['x'] + box[0], meta['y'] + box[1]))
    if not layers:raise ValueError('Empty required locomotion frame: ' + str(index))
    x0=min(x for _,x,y in layers); y0=min(y for _,x,y in layers)
    x1=max(x+im.width for im,x,y in layers); y1=max(y+im.height for im,x,y in layers)
    image=Image.new('RGBA',(x1-x0,y1-y0))
    for part,x,y in layers:image.alpha_composite(part,(x-x0,y-y0))
    return image,[x0,y0]

def build(src, atlas_type):
    avatar=['sprite/character/swordman/equipment/avatar/'+p for p in AVATAR]
    chr_path='character/swordman/swordman.chr'
    chr_source=src.lib.script(chr_path,'chr')
    src.sources[chr_path]=chr_source['sha256']
    clips={k:dict(src.animation(MOTION_DIR+name+'.ani'), source_ani=MOTION_DIR+name+'.ani')
           for k,name in [('stay','rest'),('move','move'),('dash','dash')]}
    town_atlas=atlas_type('motion_town')
    for index in sorted({f['img_frame'] for clip in clips.values() for f in clip['frames']}):
        image,offset=compose(src,avatar,index)
        town_atlas.add(index,image,offset)
    town={'bank':town_atlas.save(),'clips':clips,'weapon_visible':False,
          'basis':'CHR rest motion; complete avatar walk/dash; SIMPLE motion IMG is only a white silhouette and is not used.'}
    battle={}
    for key,weapon in WEAPONS.items():
        paths=[f'sprite/character/swordman/equipment/weapon/{weapon}/{weapon}0000b.img']+avatar+[f'sprite/character/swordman/equipment/weapon/{weapon}/{weapon}0000c.img']
        atlas=atlas_type('motion_'+key)
        for index in sorted({f['img_frame'] for pose in ['move','dash'] for f in clips[pose]['frames']}):
            image,offset=compose(src,paths,index)
            atlas.add(index,image,offset)
        bank=atlas.save()
        battle[key]={'move':bank,'dash':bank}
    return {'schema':'dnf_player_locomotion/1','town':town,'battle':battle,
            'source_chr':{'path':chr_path,'sha256':chr_source['sha256']},
            'avatar_layers':avatar,'native_scale':1,'frame_filtering':False,
            'known_old_exposure_frames':{'move':[181,185],'dash':[105,109]},
            'interpretation':'Skin before both pants/shoes partitions; town hides held weapon (presentation adaptation).'}
