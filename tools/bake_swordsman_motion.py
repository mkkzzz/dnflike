"""Bake shared native body/finger motion and one coupled replaceable weapon.

Requires tools/requirements-motion.txt. RTMPose is only a landmark drafting aid;
the bake consumes explicit reviewed JSON, never a live pose-model prediction.
Source proportion gates run before any motion or local head normalization.
"""
from __future__ import annotations
from pathlib import Path
import argparse,copy,hashlib,json,math,shutil,os
import numpy as np
from PIL import Image,ImageDraw
from actor_motion import Tween,geometry,controls,tps_map,remap,premultiply,straight,shortest
from check_actor_proportions import assess
from explore.swordsman_layer_trial import select_weapon,weapon_image,placement_matrix

ROOT=Path(__file__).resolve().parents[1]
SOURCES=ROOT/'art/animations/players/swordsman/v7/sources'
OLD=ROOT/'art/animations/players/swordsman/v7/exports/base_runtime_c5'
OUT=ROOT/'art/animations/players/swordsman/v7/exports/base_runtime_c6'
GAME=ROOT/'game/assets/swordsman_v7_c6'
HEAD=54.0
JOINTS=[5,6,7,8,9,10,11,12,13,14,15,16,20,21,24,25]
PROFILES=['katana','greatsword','shortsword']
read=lambda p:json.loads(p.read_text(encoding='utf-8'))
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,d):
 p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')

def full_layer(ref,folder=OLD):
 im=Image.new('RGBA',(1024,1080))
 if ref:im.alpha_composite(Image.open(folder/ref['file']).convert('RGBA'),tuple(ref['rect'][:2]))
 return im

def retarget(body,fingers,marks,target):
 box=body.getchannel('A').getbbox();x0=max(0,box[0]-40);y0=max(0,box[1]-40);x1=min(1024,box[2]+40);y1=min(1080,box[3]+40)
 mapping=tps_map(controls(target),controls(marks),(x1-x0,y1-y0),(x0,y0))
 def deform(im):
  out=np.zeros((1080,1024,4),np.uint8);out[y0:y1,x0:x1]=straight(remap(premultiply(im.crop((x0,y0,x1,y1))),mapping));return Image.fromarray(out)
 return deform(body),deform(fingers),target

def normalize_head(body,fingers,marks):
 # Preserve the smallest already-valid source head; never enlarge it to a cap.
 if marks['head_size']<=HEAD:return body,fingers,copy.deepcopy(marks)
 target=copy.deepcopy(marks);angle=marks['head_angle'];diff=(marks['head_size']-HEAD)*.5
 target['head_center']=(np.asarray(marks['head_center'])+np.array([math.sin(angle),math.cos(angle)])*diff).tolist();target['head_size']=HEAD
 signature=hashlib.sha256(b'calibrated_hands_v2'+body.tobytes()+fingers.tobytes()+json.dumps(marks,sort_keys=True).encode()+str(HEAD).encode()).hexdigest()
 cache=OUT/'keyposes';cache.mkdir(parents=True,exist_ok=True);bfile=cache/(signature+'_body.png');ffile=cache/(signature+'_fingers.png')
 if bfile.exists() and ffile.exists():return Image.open(bfile).convert('RGBA'),Image.open(ffile).convert('RGBA'),target
 b,f,m=retarget(body,fingers,marks,target);b.save(bfile);f.save(ffile);return b,f,m

def load_marks(joints):
 result={};provenance=[]
 configs=list((SOURCES/'base_batch_c5').glob('*/body_config.json'))+list((SOURCES/'base_batch_c6').glob('*/body_config.json'))
 for path in configs:
  audit=read(path.parent/'proportions.json');report=assess(path,path.parent/'proportions.json')
  if not report['passed'] or not audit.get('landmark_semantics_reviewed'):raise ValueError('Unreviewed or failed proportion gate '+str(path))
  c=read(path);bm=(path.parent/c['output_dir']/'manifest.json').resolve();m=read(bm)
  if m['config_sha256']!=sha(path):raise ValueError('Stale native body export '+str(path))
  for source in m['sources'].values():
   raw=(path.parent/source['file']).resolve()
   if sha(raw)!=source['sha256']:raise ValueError('Stale original drawing '+str(raw))
  anns={a['pose_id']:a for a in audit['poses']}
  for clip in m['clips'].values():
   for f in clip['frames']:
    pid=f['source_pose'];ann=anns[pid];h=ann['head'];axis=[0,1]
    if h['projection']=='reviewed_in_plane_roll':axis=read(path.parent/ann['projection_profile']['file'])['axis_down']
    s=f['scale'];rx,ry=f['source_root'];top,chin=h['hair_top'],h['chin']
    center=[448+((top[0]+chin[0])*.5-rx)*s,840+((top[1]+chin[1])*.5-ry)*s]
    jp=joints['poses'].get(pid)
    if not jp or not jp.get('reviewed') or sha(ROOT/jp['file'])!=jp['sha256']:raise ValueError('Missing/stale reviewed joints '+pid)
    result[pid]={'head_center':center,'head_size':sum((b-a)*n for a,b,n in zip(top,chin,axis))*s,'head_angle':math.atan2(axis[0],axis[1]),'root':[448,840],'joints':[jp['points'][i]for i in JOINTS]}
  provenance.append({'config':path.relative_to(ROOT).as_posix(),'sha256':sha(path),'audit_sha256':sha(path.parent/'proportions.json'),'manifest':bm.relative_to(ROOT).as_posix(),'manifest_sha256':sha(bm)})
 return result,provenance

def main():
 p=argparse.ArgumentParser();p.add_argument('--only',nargs='*');p.add_argument('--install',action='store_true');p.add_argument('--legacy-dis',action='store_true');args=p.parse_args()
 model=Path(os.environ.get('SWORDSMAN_RIFE_MODEL',''))
 if not args.legacy_dis and not (model/'flownet.bin').is_file():raise ValueError('Set SWORDSMAN_RIFE_MODEL to the official RIFE 4.6 model directory; DIS trials cannot be installed')
 if not args.legacy_dis:
  from setup_motion_model import FILES
  if any(sha(model/file)!=expected for file,expected in FILES.items()):raise ValueError('Unrecognized motion model; refuse replacing the audited RIFE 4.6 weights')
 backend={'name':'RIFE 4.6 correspondence and occlusion, shared premultiplied RGBA/finger sampling','upstream':'https://github.com/nihui/rife-ncnn-vulkan/releases/tag/20221029','license':'MIT','model_sha256':{p.name:sha(p)for p in model.glob('flownet.*')}} if not args.legacy_dis else {'name':'rejected_DIS_experiment'}
 joints=read(SOURCES/'base_batch_c6/motion_joints.json')
 if not joints.get('reviewed'):raise ValueError('Review the limb overlays before baking')
 marks,provenance=load_marks(joints);old=read(OLD/'manifest.json')
 if not old['validation']['passed'] or any(sha(OLD/t['file'])!=t['sha256']for t in old['textures'].values()):raise ValueError('Previous native source layers are stale or corrupted')
 layer_cfg_path=SOURCES/'base_batch_c5/attack1/layer_config.json';layer_cfg=read(layer_cfg_path)
 weapon_inputs={'config_sha256':sha(layer_cfg_path),'sources':{name:sha((layer_cfg_path.parent/spec['file']).resolve())for name,spec in layer_cfg['weapons'].items()}}
 recipe=hashlib.sha256(json.dumps([provenance,sha(SOURCES/'base_batch_c6/motion_joints.json'),sha(OLD/'manifest.json'),backend,weapon_inputs,{f:sha(ROOT/'tools'/f)for f in ['bake_swordsman_motion.py','actor_motion.py','motion_neural.py','setup_motion_model.py']}],sort_keys=True).encode()).hexdigest()
 weapons={};textures={};keys={};wrist_reviews=[]
 airborne=['air_attack','jump','jump_rise','jump_apex','jump_fall','air_hit','back_dash']
 ground_poses={f['source_pose']for name,c in old['clips'].items() if name not in airborne for f in c['frames']}
 OUT.mkdir(parents=True,exist_ok=True)
 def layer(im):
  im=im.convert('RGBA');box=im.getchannel('A').getbbox()
  if not box:return {}
  cut=im.crop(box);ident=hashlib.sha256(str(cut.size).encode()+cut.tobytes()).hexdigest();file='layers/'+ident+'.png';target=OUT/file
  if ident not in textures:
   target.parent.mkdir(exist_ok=True)
   if not target.exists():cut.save(target)
   textures[ident]={'file':file,'sha256':sha(target),'size':list(cut.size)}
  return {'file':file,'rect':[box[0],box[1],box[2]-box[0],box[3]-box[1]]}
 for name,spec in layer_cfg['weapons'].items():
  raw,wm=select_weapon((SOURCES/'base_batch_c5/attack1'/spec['file']).resolve(),spec);file='weapons/'+name+'.png';target=OUT/file;target.parent.mkdir(exist_ok=True);raw.save(target)
  weapons[name]=(raw,wm,spec);textures['weapon_'+name]={'file':file,'sha256':sha(target),'size':list(raw.size)}
 def base(key):
  pid=key['source_pose']
  if pid in keys:return keys[pid]
  m=copy.deepcopy(marks[pid]);m['grip']=key['profiles']['katana']['grip']
  m['secondary_grip']=list(m['joints'][JOINTS.index(9)])
  body,fingers,m=normalize_head(full_layer(key['body']),full_layer(key['fingers']),m)
  profiles={}
  for name,pf in key['profiles'].items():
   _,wm,spec=weapons[name];d=np.asarray(wm['tip'])-wm['guard'];length=np.linalg.norm(d);unit=d/length;side=np.array([-unit[1],unit[0]]);edge=np.asarray(wm['cutting_edge'])-wm['spine'];parallel=edge@unit;perp=edge@side;scale=256*spec['blade_length_multiplier']/length
   u=(np.asarray(pf['tip'])-pf['guard'])/(256*spec['blade_length_multiplier']);v=((np.asarray(pf['cutting_edge'])-pf['spine'])/scale-u*parallel)/perp
   profiles[name]={'u':u.tolist(),'v':v.tolist(),'layer':'back' if pf['back'] else 'front'}
   if pid in ground_poses and pf['tip'][1]>834:
    handpos=np.asarray(pf['grip']);tipvec=np.asarray(pf['tip'])-handpos;r=np.linalg.norm(tipvec);limit=(834-handpos[1])/r
    if not -1<=limit<=1:raise ValueError('Ground pose hand is below viable blade plane '+pid)
    alpha=math.asin(limit);current=math.atan2(tipvec[1],tipvec[0]);deltas=[(candidate-current+math.pi)%(2*math.pi)-math.pi for candidate in [alpha,math.pi-alpha]];delta=min(deltas,key=abs)
    rotation=np.array([[math.cos(delta),-math.sin(delta)],[math.sin(delta),math.cos(delta)]]);u=rotation@u;v=rotation@v;profiles[name].update(u=u.tolist(),v=v.tolist())
    wrist_reviews.append({'pose':pid,'profile':name,'angle_offset_degrees':math.degrees(delta),'reason':'Explicit offline low-pose wrist-plane correction; physical blade length and grip preserved, target tipY834. No runtime floor clamp.'})
  row={'pose':pid,'body':body,'fingers':fingers,'geometry':m,'profiles':profiles,'two_hand':False};keys[pid]=row;return row
 for c in old['clips'].values():
  for f in c['frames']:
   if not f['source_pose'].startswith(('attack1','attack2','attack3')):base(f)
 for group in ['attack1','attack2','attack3']:
  folder=SOURCES/'base_batch_c6'/group;c=read(folder/'body_config.json');bm=(folder/c['output_dir']/'manifest.json').resolve();hand=read(folder/'hand_calibration.json')
  for f in read(bm)['clips']['keys']['frames']:
   pid=f['source_pose'];body=Image.open(bm.parent/f['file']).convert('RGBA');s=f['scale'];rx,ry=f['source_root'];point=lambda p:np.array([448+(p[0]-rx)*s,840+(p[1]-ry)*s])
   primary=point(hand[pid]['primary']);secondary=point(hand[pid]['secondary']);delta=primary-secondary;u=delta/np.linalg.norm(delta);v=np.array([-u[1],u[0]])
   m=copy.deepcopy(marks[pid]);m['grip']=primary.tolist();m['secondary_grip']=secondary.tolist();finger_mask=Image.new('L',body.size);draw=ImageDraw.Draw(finger_mask)
   for x,y in [primary,secondary]:draw.ellipse((x-9,y-9,x+9,y+9),fill=255)
   # Clear the authored empty hilt channel, retaining actual skin fingers above it.
   original=np.asarray(body).copy();clean=original.copy();channel=Image.new('L',body.size);ImageDraw.Draw(channel).line([tuple(secondary-u*9),tuple(primary+u*9)],fill=255,width=5)
   ch=np.asarray(channel)>0;clean[ch,3]=0;fi=np.asarray(Image.composite(body,Image.new('RGBA',body.size),finger_mask)).copy()
   skin=(fi[:,:,0]>150)&(fi[:,:,1]>90)&(fi[:,:,2]>65);fi[ch&~skin,3]=0
   body,fingers,m=normalize_head(Image.fromarray(clean),Image.fromarray(fi),m)
   if pid=='c6_rise_low':
    original_marks=copy.deepcopy(m);u=u*.65;new_secondary=primary-u*np.linalg.norm(delta);offset=new_secondary-np.asarray(m['secondary_grip'])
    m['secondary_grip']=new_secondary.tolist();m['joints'][JOINTS.index(9)]=(np.asarray(m['joints'][JOINTS.index(9)])+offset).tolist()
    body,fingers,m=retarget(body,fingers,original_marks,m)
   profiles={name:{'u':u.tolist(),'v':v.tolist(),'layer':'front'}for name in PROFILES}
   keys[pid]={'pose':pid,'body':body,'fingers':fingers,'geometry':m,'profiles':profiles,'two_hand':True,'grip_span':float(np.linalg.norm(delta)),'secondary':secondary.tolist()}
 idle=base(old['clips']['idle']['frames'][0]);right=keys['c6_right_contact'];left=keys['c6_left_contact'];follow=keys['c6_left_follow'];low=keys['c6_rise_low'];rise=keys['c6_rise_contact']
 # The visible sweeps straddle the existing V6 hit windows (8..12 / 8..12 /
 # 12..15). Preserve combat clocks while putting actual forward blade travel
 # inside them; leftward follow-through alone cannot hit a target in front.
 combo={'attack1':[(0,idle),(7,right),(13,left),(17,follow),(25,idle)],'attack2':[(0,follow),(4,left),(12,right),(26,idle)],'attack3':[(0,right),(6,low),(16,rise),(34,idle)]}
 clips={};count=0
 for name,c in old['clips'].items():
  if args.only and name not in args.only:continue
  checkpoint=OUT/(name+'.checkpoint.json')
  if checkpoint.exists():
   cached=read(checkpoint)
   if cached.get('recipe_sha256')==recipe:
    refs=[f[layer]for f in cached['frames']for layer in ['body','fingers']]+[f['profiles'][profile][side]for f in cached['frames']for profile in PROFILES for side in ['back','front']]
    if all(not r or (OUT/r['file']).is_file()for r in refs):
     for ref in refs:
      if ref:
       file=OUT/ref['file'];textures[ref['file']]={'file':ref['file'],'sha256':sha(file),'size':list(Image.open(file).size)}
     clips[name]=cached;count+=len(cached['frames']);print('resume',name,len(cached['frames']),flush=True);continue
  duration=18 if name=='jump_land' else c['duration_ticks'];sequence=combo[name] if name in combo else [(f['start_tick'],base(f))for f in c['frames']];sequence=list(sequence)
  if name=='jump_land':sequence=[(0,base(c['frames'][0])),(duration-1,idle)]
  if name in combo:
   contextual=[]
   for at,key in sequence:
    key=dict(key);key['profiles']=copy.deepcopy(key['profiles'])
    if key['two_hand']:
     for profile in PROFILES:
      u=np.asarray(key['profiles'][profile]['u']);normal=np.array([-u[1],u[0]])/np.linalg.norm(u);key['profiles'][profile]['v']=(normal*(-1 if name in ['attack1','attack3'] else 1)).tolist()
    contextual.append((at,key))
   sequence=contextual
  if name in ['jump_land','guard_end','walk_stop','run_stop','getup','revive']:
   end_tick=duration-1
   if sequence[-1][0]==end_tick:sequence[-1]=(end_tick,idle)
   else:sequence.append((end_tick,idle))
  sequence.append((duration,sequence[0][1] if c['loop'] else sequence[-1][1]));frames=[]
  for segment in range(len(sequence)-1):
   start,a=sequence[segment];end,b=sequence[segment+1]
   if end<=start:raise ValueError('Nonmonotonic source clock')
   tween=Tween(a['body'],b['body'],a['geometry'],b['geometry'],a['fingers'],b['fingers'],arms=name not in ['walk','run','walk_start','walk_stop','run_start','run_stop','idle'])
   path_angles={}
   for profile in PROFILES:
    ua=np.asarray(a['profiles'][profile]['u']);ub=np.asarray(b['profiles'][profile]['u']);aa=math.atan2(ua[1],ua[0]);ab=shortest(aa,math.atan2(ub[1],ub[0]));_,wm,spec=weapons[profile]
    unit=np.asarray(wm['tip'],dtype=float)-wm['guard'];source_length=np.linalg.norm(unit);unit/=source_length;side=np.array([-unit[1],unit[0]]);tipvec=np.asarray(wm['tip'])-wm['grip'];scale=256*spec['blade_length_multiplier']/source_length;along=tipvec@unit*scale;across=tipvec@side*scale
    def ceiling(angle_end):
     result=-math.inf
     for at in np.linspace(0,1,41):
      angle=aa*(1-at)+angle_end*at;projection=np.linalg.norm(ua)*(1-at)+np.linalg.norm(ub)*at;grip_y=a['geometry']['grip'][1]*(1-at)+b['geometry']['grip'][1]*at
      result=max(result,grip_y+math.sin(angle)*projection*along+abs(math.cos(angle)*across))
     return result
    if name not in airborne and ceiling(ab)>843.5:
     candidates=[x for x in [ab-2*math.pi,ab+2*math.pi]if ceiling(x)<=843.5]
     if candidates:
      selected=min(candidates,key=lambda x:abs(x-aa));wrist_reviews.append({'clip':name,'source':a['pose'],'target':b['pose'],'profile':profile,'angle_path_degrees':[math.degrees(aa),math.degrees(selected)],'reason':'Offline reviewed recovery arc above the floor, with full physical blade length; no runtime clamp.'});ab=selected
    path_angles[profile]=(aa,ab)
   for tick in range(start,end):
    t=(tick-start)/(end-start);geom=geometry(a['geometry'],b['geometry'],t);pa=copy.deepcopy(a['profiles']);pb=b['profiles'];placements={}
    # Left/right sweeps use an authored 3D horizontal plane, with the midpoint
    # foreshortened toward camera. Both hands are retargeted on this SAME hilt.
    horizontal=name in ['attack1','attack2'] and a['two_hand'] and b['two_hand'] and a['pose']!=b['pose'] and {a['pose'],b['pose']}=={'c6_right_contact','c6_left_contact'}
    shared_u=None
    if horizontal:
     yaw=(math.pi*t if name=='attack1' else math.pi*(1-t));shared_u=np.array([math.cos(yaw),-.22*math.sin(yaw)])
    for profile in PROFILES:
     ua0=np.asarray(pa[profile]['u']);ub0=np.asarray(pb[profile]['u'])
     angle_a,angle_b=path_angles[profile]
     if name in combo and a['two_hand'] and not b['two_hand'] and ua0[0]<0 and ub0[0]>0:
      # Recover over the shoulder rather than passing the blade through soil.
      while angle_b<angle_a:angle_b+=2*math.pi
     angle=angle_a*(1-t)+angle_b*t;projection=np.linalg.norm(ua0)*(1-t)+np.linalg.norm(ub0)*t
     u=np.array([math.cos(angle),math.sin(angle)])*projection if shared_u is None else shared_u
     if np.linalg.norm(u)<.035:u=np.array([u[0],-.035])
     ua,va=pa[profile]['u'],pa[profile]['v'];ub,vb=pb[profile]['u'],pb[profile]['v'];side_a=(ua[0]*va[1]-ua[1]*va[0])/max(.001,math.hypot(*ua));side_b=(ub[0]*vb[1]-ub[1]*vb[0])/max(.001,math.hypot(*ub))
     sign=float(side_a*(1-t)+side_b*t)
     if abs(sign)<.025:sign=.025 if sign>=0 else -.025
     normal=np.array([-u[1],u[0]])/np.linalg.norm(u);v=normal*sign
     placements[profile]=(u,v)
    if a['two_hand'] and b['two_hand']:
     u=placements['katana'][0];span=a['grip_span']*(1-t)+b['grip_span']*t
     # Wrist targets include the physical hand separation projected by the blade plane.
     primary=np.asarray(geom['grip']);secondary=primary-u*span
     old_secondary=np.asarray(geom['secondary_grip']);offset=secondary-old_secondary
     geom['secondary_grip']=secondary.tolist();geom['joints'][JOINTS.index(9)]=(np.asarray(geom['joints'][JOINTS.index(9)])+offset).tolist()
    body,fingers,geom=tween.sample(t,geom)
    f={'source_pose':a['pose'],'target_pose':b['pose'],'source_mix':round(t,8),'start_tick':tick,'duration_ticks':1,'height_px':0,'root_dx':0,'body':layer(Image.fromarray(body)),'fingers':layer(Image.fromarray(fingers)),'motion_geometry':geom,'profiles':{},'edge_intent':'coupled body/hand/weapon motion; actual texture cutting edge bound to authored swing','allow_edge_roll_from_previous':True}
    for profile,(u,v) in placements.items():
     raw,wm,spec=weapons[profile];length=256*spec['blade_length_multiplier'];handpos=geom['grip'];angle=math.atan2(u[1],u[0]);rendered,sampling=weapon_image(raw,wm,(1024,1080),handpos,angle,length,(u,v));matrix,_=placement_matrix(wm,angle,length,(u,v));ma,mb,mc,md=matrix
     def placed(mark):
      dx,dy=np.asarray(mark)-wm['grip'];return [float(handpos[0]+ma*dx+mb*dy),float(handpos[1]+mc*dx+md*dy)]
     guard,tip=placed(wm['guard']),placed(wm['tip']);edge,spine=placed(wm['cutting_edge']),placed(wm['spine']);direction=np.asarray(edge)-spine
     if name not in airborne and tip[1]>844:raise ValueError(f'Weapon crosses floor: {name} t{tick} {profile} {tip[1]}')
     back=pa[profile]['layer']=='back' and (t<.5 or pb[profile]['layer']=='back');ref=layer(rendered)
     f['profiles'][profile]={'back':ref if back else {},'front':{} if back else ref,'grip':handpos,'guard':guard,'tip':tip,'cutting_edge':edge,'spine':spine,'basis_u':u.tolist(),'basis_v':v.tolist(),'matrix':list(matrix),'raw_weapon':'weapons/'+profile+'.png','raw_grip':wm['grip'],'physical_blade_length':length,'source_sampling_scale':sampling,'edge_review':{'authored_cutting_direction':direction.tolist(),'cutting_alignment':1.0,'texture_cutting_side':1}}
    if name=='death':f['reused_from']=next((x.get('reused_from','death')for x in c['frames'] if x['start_tick']<=tick<x['start_tick']+x['duration_ticks']),'death')
    frames.append(f);count+=1
   print(name,a['pose'],b['pose'],end-start,flush=True)
  clips[name]={'semantic_id':c['semantic_id'],'duration_ticks':duration,'loop':c['loop'],'root_mode':c['root_mode'],'frames':frames,'motion_mode':'native_feature_aligned_occlusion_60hz','source_key_count':len(sequence)-1,'recipe_sha256':recipe}
  write(OUT/(name+'.checkpoint.json'),clips[name])
 complete=len(clips)==32
 validation={'passed':complete and not args.legacy_dis,'native_standing_height':380,'native_head_span_cap':HEAD,'head_span_range':[min(k['geometry']['head_size']for k in keys.values()),max(k['geometry']['head_size']for k in keys.values())],'head_upscale_allowed':False,'dense_frames':count,'source_proportion_gates_passed':True,'source_head_normalization':'shrink only, rigid head corners pivot at jaw; already-smaller valid heads preserved, never enlarged','artwork_approved':False,'runtime_user_approved':False}
 manifest={k:copy.deepcopy(old[k])for k in ['fps','native_canvas','anchor','native_standing_height','world_scale','profiles','alpha_mode','blend','actor_includes_weapon','hitstop_baked','layer_order','authorization','coverage']}
 manifest.update(schema='swordsman_runtime_layers/2',revision='v7_base_runtime_c6',clips=clips,textures=textures,validation=validation,source_inputs=provenance,combo_rising=True,joints_sha256=sha(SOURCES/'base_batch_c6/motion_joints.json'))
 manifest['weapon_sources']={name:{'file':'weapons/'+name+'.png','marks':wm,'physical_blade_length':256*spec['blade_length_multiplier']}for name,(_,wm,spec)in weapons.items()}
 manifest['motion_backend']=backend;manifest['recipe_sha256']=recipe
 manifest['weapon_inputs']=weapon_inputs
 manifest['coverage'].update(complete=complete,scope='non-skill base actions; user-requested two-hand horizontal/horizontal/rising combo')
 if args.install:
  approval=read(SOURCES/'base_batch_c7/idle_approval.json')
  if clips.get('idle')!=approval['clip']:raise ValueError('Accepted idle is frozen: reuse its exact clip and rasters before installing a new bake')
  for file,digest in approval['textures'].items():
   if sha(OUT/file)!=digest:raise ValueError('Accepted idle raster changed: '+file)
 write(OUT/'manifest.json',manifest);write(OUT/'validation.json',validation);write(OUT/'wrist_plane_review.json',wrist_reviews)
 if args.install:
  if not validation['passed']:raise ValueError('Refuse installing an incomplete or rejected bake')
  for path in [OUT/'manifest.json',OUT/'validation.json']+[OUT/t['file']for t in textures.values()]:
   dest=GAME/path.relative_to(OUT);dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(path,dest)
 print(json.dumps(validation,ensure_ascii=False),flush=True)
if __name__=='__main__':main()
