"""Bake a review-only v7 weapon-layer trial from measured body frames and real art.

No poses are invented. All three profiles reference identical body/finger PNGs
and integer clocks. Source editing is performed by image_gen, never this tool.
This package is not a Godot runtime adapter or an automatic G3 art approval.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFont, ImageOps

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'tools'))
from check_actor_proportions import assess


def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def edge_clear(image):
    alpha=image.getchannel('A')
    return all(alpha.crop(box).getextrema()[1]==0 for box in
               [(0,0,image.width,1),(0,image.height-1,image.width,image.height),
                (0,0,1,image.height),(image.width-1,0,image.width,image.height)])


def select_weapon(path, spec):
    if sha(path)!=spec['sha256']:
        raise ValueError('Weapon source hash changed: '+str(path))
    with Image.open(path) as opened:
        image=opened.convert('RGBA').crop(spec['crop_bbox'])
    x0,y0,_,_=spec['crop_bbox']
    seed=tuple(round(v-offset) for v,offset in zip(spec['component_seed'],(x0,y0)))
    alpha=image.getchannel('A'); core=alpha.point(lambda a:255 if a>64 else 0)
    if not core.getpixel(seed):
        raise ValueError('Weapon seed is not on a visible core')
    flood=core.copy();ImageDraw.floodfill(flood,seed,128)
    mask=flood.point(lambda a:255 if a==128 else 0)
    # Select existing pixels only; never paint steel, hilt or replacement hands.
    image=Image.composite(image,Image.new('RGBA',image.size),mask)
    names=['grip','guard','tip']+[n for n in ['cutting_edge','spine'] if n in spec]
    marks={name:[spec[name][0]-x0,spec[name][1]-y0] for name in names}
    for name,(x,y) in marks.items():
        if image.getchannel('A').crop((max(0,round(x)-3),max(0,round(y)-3),min(image.width,round(x)+4),min(image.height,round(y)+4))).getextrema()[1]<128:
            raise ValueError('Invisible canonical weapon landmark: '+name)
    return image,marks


def projection_basis(pose,camera,target_angle):
    """Orthographic projection of authored 3D blade/edge axes, aligned to art."""
    def unit(v):
        length=math.sqrt(sum(n*n for n in v))
        if length<1e-8:raise ValueError('Degenerate blade basis')
        return [n/length for n in v]
    d=unit(pose['blade_dir']);raw=pose['blade_edge']
    dot=sum(a*b for a,b in zip(d,raw));e=unit([b-a*dot for a,b in zip(d,raw)])
    yaw,pitch=math.radians(camera['yaw']),math.radians(camera['pitch'])
    def project(v):
        x=math.cos(yaw)*v[0]+math.sin(yaw)*v[2]
        z=-math.sin(yaw)*v[0]+math.cos(yaw)*v[2]
        y=math.cos(pitch)*v[1]-math.sin(pitch)*z
        return [x,-y]
    u,v=project(d),project(e)
    if math.hypot(*u)<.15:raise ValueError('Blade pointing into camera needs separately authored view')
    angle=target_angle-math.atan2(u[1],u[0]);c,s=math.cos(angle),math.sin(angle)
    rotate=lambda p:[c*p[0]-s*p[1],s*p[0]+c*p[1]]
    u,v=rotate(u),rotate(v)
    if abs(u[0]*v[1]-u[1]*v[0])<.08:
        raise ValueError('Edge-on blade needs a reviewed spine texture, not a collapsed sheet')
    return u,v


def placement_matrix(marks,target_angle,blade_length,basis=None):
    dx=marks['tip'][0]-marks['guard'][0];dy=marks['tip'][1]-marks['guard'][1]
    source_length=math.hypot(dx,dy);scale=blade_length/source_length
    if not 0<scale<=1:
        raise ValueError('Weapon would upscale source pixels')
    sx,sy=dx/source_length,dy/source_length
    if basis is None:
        basis=([math.cos(target_angle),math.sin(target_angle)],[-math.sin(target_angle),math.cos(target_angle)])
    u,v=basis
    matrix=(scale*(u[0]*sx-v[0]*sy),scale*(u[0]*sy+v[0]*sx),
            scale*(u[1]*sx-v[1]*sy),scale*(u[1]*sy+v[1]*sx))
    return matrix,scale


def cutting_edge_basis(basis, marks, cutting_direction):
    """Bind the real texture's cutting side to an explicitly authored direction.

    A projected blade_edge axis alone has no texture-side semantics. In the
    first trial that missing binding reversed the katana in several poses.
    Only reflect the transverse axis; preserve the tip direction/foreshortening.
    The old trial remains reproducible when no edge contract is requested.
    """
    if 'cutting_edge' not in marks or 'spine' not in marks:
        raise ValueError('Weapon needs explicit cutting_edge and spine landmarks')
    dx=marks['tip'][0]-marks['guard'][0];dy=marks['tip'][1]-marks['guard'][1]
    ex=marks['cutting_edge'][0]-marks['spine'][0];ey=marks['cutting_edge'][1]-marks['spine'][1]
    side=dx*ey-dy*ex
    if abs(side)<1e-6:raise ValueError('Cutting edge and spine do not define a texture side')
    u,v=[list(axis) for axis in basis]
    nx,ny=cutting_direction
    if math.hypot(nx,ny)<1e-6:raise ValueError('Missing authored cutting direction')
    # The texture normal is (-dy,dx); source cutting side may be either sign.
    sign=1 if side>0 else -1
    alignment=(v[0]*nx+v[1]*ny)*sign/math.hypot(nx,ny)/math.hypot(*v)
    if abs(alignment)<.2:raise ValueError('Cutting direction is ambiguous relative to blade edge')
    reflected=alignment<0
    if reflected:v=[-n for n in v]
    return (u,v),{'texture_cutting_side':sign,'transverse_axis_reflected':reflected,
                  'authored_cutting_direction':list(cutting_direction),
                  'cutting_alignment':abs(alignment)}


def weapon_image(image, marks, size, hand, target_angle, blade_length,basis=None):
    gx,gy=marks['grip'];matrix,scale=placement_matrix(marks,target_angle,blade_length,basis)
    a,b,c,d=matrix;det=a*d-b*c
    if abs(det)<1e-9:raise ValueError('Collapsed weapon projection')
    trace=a*a+b*b+c*c+d*d
    sampling_norm=math.sqrt((trace+math.sqrt(max(0,trace*trace-4*det*det)))/2)
    if sampling_norm>1+1e-9:raise ValueError('Projected weapon would upscale source pixels')
    # Supersample only while source sampling remains <=1, then downsample.
    # A direct bicubic minification aliases thin steel and wrap details.
    supersample=min(3,max(1,math.floor(1/sampling_norm)))
    ia,ib,ic,id=d/det/supersample,-b/det/supersample,-c/det/supersample,a/det/supersample
    hx,hy=(hand[0]*supersample,hand[1]*supersample)
    inverse=(ia,ib,gx-ia*hx-ib*hy,ic,id,gy-ic*hx-id*hy)
    result=image.convert('RGBa').transform((size[0]*supersample,size[1]*supersample),Image.Transform.AFFINE,inverse,Image.Resampling.BICUBIC)
    if supersample>1:result=result.resize(size,Image.Resampling.LANCZOS)
    result=result.convert('RGBA')
    if not edge_clear(result):
        raise ValueError('Weapon reaches export canvas edge')
    return result,scale


def bake(config_path):
    config_path=Path(config_path).resolve();base=config_path.parent;config=read(config_path)
    output=(base/config['output_dir']).resolve()
    allowed=ROOT/'art/animations/players/swordsman/v7/exports'
    if not output.is_relative_to(allowed.resolve()) or output==allowed.resolve():
        raise ValueError('Trial output must be a new candidate under v7 exports')
    manifest_path=(base/config['body_manifest']).resolve();body_manifest=read(manifest_path)
    body_config=(base/config['body_config']).resolve();body_audit=(base/config['body_audit']).resolve()
    report=assess(body_config,body_audit)
    if not report['passed'] or sha(body_config)!=body_manifest['config_sha256']:
        raise ValueError('Body proportion preflight failed or body package is stale')
    if body_manifest['actor_includes_weapon']:
        raise ValueError('Layer trial requires a weaponless body package')
    body_inputs=read(body_config)
    for key,source in body_inputs['sources'].items():
        if sha((body_config.parent/source['file']).resolve())!=body_manifest['sources'][key]['sha256']:
            raise ValueError('Body package was not rebuilt from the current source')
    if set(config['weapons'])!={'katana','greatsword','shortsword'}:
        raise ValueError('All three representative weapon profiles are mandatory')
    guide_path=(base/config['projection_guide']['file']).resolve()
    if sha(guide_path)!=config['projection_guide']['sha256']:
        raise ValueError('Projection guide hash changed')
    guide=read(guide_path)
    clip_name=config.get('clip_name','attack1')
    clip=body_manifest['clips'][clip_name];anchor=clip['anchor'];size=tuple(clip['size'])
    if clip['duration_ticks']!=config.get('duration_ticks',30) or set(config['poses'])!={f['source_pose'] for f in clip['frames']}:
        raise ValueError('Trial requires the complete measured clip pose mapping and clock')
    images={};weapons={};prepared=[]
    for name,spec in config['weapons'].items():
        source=(base/spec['file']).resolve()
        image,marks=select_weapon(source,spec)
        weapons[name]=(image,marks,spec)
        images[f'weapons/{name}.png']=image
    for index,frame in enumerate(clip['frames']):
        pid=frame['source_pose'];author=config['poses'][pid]
        body_path=manifest_path.parent/frame['file']
        if sha(body_path)!=author['body_sha256']:
            raise ValueError('Body pixels changed: '+pid)
        with Image.open(body_path) as opened:body=opened.convert('RGBA')
        if body.size!=size or not edge_clear(body):raise ValueError('Invalid body canvas')
        scale=frame['scale'];rx,ry=frame['source_root']
        def point(p):return (anchor[0]+(p[0]-rx)*scale,anchor[1]+(p[1]-ry)*scale)
        hand=point(author['grip']);guard=point(author['guard']);tip=point(author['tip'])
        angle=math.atan2(tip[1]-guard[1],tip[0]-guard[0])
        observed_length=math.dist(guard,tip)
        length=config['katana_blade_length_px']
        basis=projection_basis(guide['frames'][author['guide_pose_index']]['pose_cm'],guide['camera'],angle)
        if len(author['finger_polygon'])<3 or author['weapon_layer'] not in ['front','back']:
            raise ValueError('Every pose requires an explicit finger mask and weapon layer')
        finger_mask=Image.new('L',size)
        ImageDraw.Draw(finger_mask).polygon([point(p) for p in author['finger_polygon']],fill=255)
        fingers=Image.composite(body,Image.new('RGBA',size),finger_mask)
        if not fingers.getchannel('A').getbbox():raise ValueError('Empty finger occlusion')
        body_file=f'body/f{index:03d}.png';finger_file=f'fingers/f{index:03d}.png'
        images[body_file]=body;images[finger_file]=fingers
        # Body and foreground fingers are exported once and shared by profiles.
        row={'source_pose':pid,'start_tick':frame['start_tick'],'duration_ticks':frame['duration_ticks'],
             'body':body_file,'fingers':finger_file,'body_sha256':sha(body_path),
             'hand':list(hand),'guard_reference':list(guard),'tip_reference':list(tip),
             'angle_radians':angle,'reference_projected_blade_length':observed_length,
             'physical_katana_blade_length':length,'trial_projected_katana_blade_length':length*math.hypot(*basis[0]),
             'projected_blade_axis':basis[0],'projected_edge_axis':basis[1],'guide_pose_index':author['guide_pose_index'],
             'weapon_layer':author['weapon_layer'],'profiles':{}}
        row['height_px']=frame.get('height_px',0)
        row['root_dx']=frame.get('root_dx',0)
        row['edge_intent']=author.get('edge_intent','legacy unspecified')
        row['allow_edge_roll_from_previous']=author.get('allow_edge_roll_from_previous',False)
        for name,(weapon,marks,spec) in weapons.items():
            offset=math.radians(author.get('profile_angle_offsets_degrees',{}).get(name,0))
            def rotated(axis):
                return [math.cos(offset)*axis[0]-math.sin(offset)*axis[1],math.sin(offset)*axis[0]+math.cos(offset)*axis[1]]
            weapon_basis=tuple(rotated(axis) for axis in basis);edge_review=None
            if config.get('edge_contract'):
                if 'cutting_direction' not in author:
                    raise ValueError('Every pose needs an authored cutting direction')
                weapon_basis,edge_review=cutting_edge_basis(weapon_basis,marks,rotated(author['cutting_direction']))
            rendered,sampling=weapon_image(weapon,marks,size,hand,angle+offset,length*spec['blade_length_multiplier'],weapon_basis)
            back=rendered if author['weapon_layer']=='back' else Image.new('RGBA',size)
            front=rendered if author['weapon_layer']=='front' else Image.new('RGBA',size)
            combined=Image.alpha_composite(Image.alpha_composite(Image.alpha_composite(back,body),front),fingers)
            if not edge_clear(combined):raise ValueError('Composite reaches canvas edge')
            prefix=f'{name}/f{index:03d}'
            images[prefix+'_back.png']=back;images[prefix+'_front.png']=front;images[prefix+'_composite.png']=combined
            matrix,_=placement_matrix(marks,angle+offset,length*spec['blade_length_multiplier'],weapon_basis)
            ma,mb,mc,md=matrix
            def placed(mark):
                u,v=mark[0]-marks['grip'][0],mark[1]-marks['grip'][1]
                return [hand[0]+ma*u+mb*v,hand[1]+mc*u+md*v]
            row['profiles'][name]={'back':prefix+'_back.png','front':prefix+'_front.png','composite':prefix+'_composite.png','source_sampling_scale':sampling,
                                   'grip':list(hand),'guard':placed(marks['guard']),'tip':placed(marks['tip']),
                                   'blade_length_px':length*spec['blade_length_multiplier']*math.hypot(*basis[0]),
                                   'physical_blade_length_px':length*spec['blade_length_multiplier'],
                                   'source_to_canvas_matrix':list(matrix)}
            row['profiles'][name]['authored_angle_offset_degrees']=math.degrees(offset)
            if edge_review:
                row['profiles'][name]['cutting_edge']=placed(marks['cutting_edge'])
                row['profiles'][name]['spine']=placed(marks['spine'])
                row['profiles'][name]['edge_review']=edge_review
        prepared.append(row)
    return output,config,body_manifest,report,prepared,images


def previews(output,frames,images,anchor):
    # Real export pixels only. Cropping panel space never rescales the actors.
    def displayed(frame,profile):
        raw=images[profile['composite']]
        if not frame.get('height_px') and not frame.get('root_dx'):return raw
        result=Image.new('RGBA',raw.size)
        result.alpha_composite(raw,(round(frame.get('root_dx',0)),-round(frame.get('height_px',0))))
        if not edge_clear(result):raise ValueError('Preview root/height translation clips the canvas')
        return result
    bounds=[displayed(f,p).getchannel('A').getbbox() for f in frames for p in f['profiles'].values()]
    left=min(b[0] for b in bounds)-20;right=max(b[2] for b in bounds)+20
    top=min(b[1] for b in bounds)-55;bottom=max(b[3] for b in bounds)+25
    size=(right-left,bottom-top);font=ImageFont.truetype('C:/Windows/Fonts/msyh.ttc',20)
    labels={'katana':'太刀','greatsword':'巨剑','shortsword':'短剑'}
    def panel(f,name,mirror=False):
        sprite=displayed(f,f['profiles'][name])
        # Mirror all assembled layers around the same canvas axis, including hand.
        cut=sprite.crop((left,top,right,bottom))
        if mirror:cut=ImageOps.mirror(cut)
        result=Image.new('RGBA',size,'#20242b');result.alpha_composite(cut)
        d=ImageDraw.Draw(result);d.text((12,8),labels[name]+(' 朝左' if mirror else ' 朝右')+' / 共用身体帧',font=font,fill='white')
        d.line((0,anchor[1]-top,size[0],anchor[1]-top),fill='#626970')
        return result.convert('RGB')
    outputs=[]
    for mirror,stem in [(False,'three_weapons'),(True,'three_weapons_left')]:
        boards=[]
        for f in frames:
            board=Image.new('RGB',(size[0]*3,size[1]))
            for i,name in enumerate(labels):board.paste(panel(f,name,mirror),(i*size[0],0))
            boards.append(board)
        ticks=[f['duration_ticks'] for f in frames]+[18]
        playback=boards+[boards[-1]]
        boundaries=[0]
        for tick in ticks:boundaries.append(boundaries[-1]+tick)
        milliseconds=[round(t*100/60)*10 for t in boundaries]
        durations=[b-a for a,b in zip(milliseconds,milliseconds[1:])]
        folder=output/'previews';folder.mkdir(exist_ok=True)
        playback[0].save(folder/(stem+'.png'))
        for slow,suffix in [(1,''),(3,'_slow3x')]:
            playback[0].save(folder/(stem+suffix+'.gif'),save_all=True,append_images=playback[1:],duration=[x*slow for x in durations],loop=0,disposal=2,optimize=False)
        outputs.append({'file':'previews/'+stem+'.gif','action_ticks':sum(f['duration_ticks'] for f in frames),'review_end_hold_ticks':18,'fps':60,'time_quantization':'cumulative 10ms GIF rounding; slow3x has triple durations'})
    return outputs


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('config',type=Path);parser.add_argument('--overwrite',action='store_true')
    args=parser.parse_args()
    output,config,body,report,frames,images=bake(args.config)
    if output.exists() and any(output.iterdir()) and not args.overwrite:
        raise ValueError('Candidate exists; use a new version or explicit --overwrite to reproduce this unapproved trial')
    # All inputs, proportions and complete compositions passed before any writes.
    output.mkdir(parents=True,exist_ok=True)
    for name,image in images.items():
        path=output/name;path.parent.mkdir(parents=True,exist_ok=True);image.save(path)
    clip=body['clips'][config.get('clip_name','attack1')]
    manifest={'schema':'swordsman_layer_trial/1','revision':config['revision'],'status':'review_candidate',
              'fps':60,'duration_ticks':clip['duration_ticks'],'canvas':clip['size'],'anchor':clip['anchor'],
              'target_standing_height':380,'actor_includes_weapon':False,'body_and_fingers_shared_across_profiles':True,
              'root_mode':clip.get('root_mode','ground'),'height_application':'separate_height translates complete assembled layers once; virtual_ground is already baked',
              'semantic_id':clip['asset_id'],'alpha_mode':'straight','blend':'normal','hitstop_baked':False,
              'layer_order':['weapon_back','body','weapon_front','fingers'],
              'proportion_gate':report,'artwork_approved':False,'integration_allowed':False,
              'declarations':{'G1':'head_scale_numerically_passed_identity_pending','G2':'pending_user_review','G3':'layer_trial_pending_art_review','G4':'pending_user_review'},
              'config_sha256':sha(args.config),'frames':frames,
              'limitations':config['limitations']}
    manifest['weapons']={name:{'file':'weapons/'+name+'.png',
        **{key:[spec[key][0]-spec['crop_bbox'][0],spec[key][1]-spec['crop_bbox'][1]] for key in ['grip','guard','tip','cutting_edge','spine'] if key in spec},
        'blade_length_multiplier':spec['blade_length_multiplier'],'source_sha256':spec['sha256']}
        for name,spec in config['weapons'].items()}
    manifest['previews']=previews(output,frames,images,manifest['anchor'])
    manifest['files']={name:sha(output/name) for name in images}
    (output/'calibration_used.json').write_text(json.dumps(config,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
    (output/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
    print(json.dumps({'output':str(output),'body_poses':len(frames),'profiles':3,'png_files':len(images),'approved':False},ensure_ascii=False))


if __name__=='__main__':main()
