"""Same-package static grip checks; these keys are not a continuous action."""
from pathlib import Path
import argparse,copy,hashlib,json,math
import numpy as np
from PIL import Image,ImageDraw,ImageFont
from check_actor_proportions import assess
from bake_swordsman_motion import retarget
from explore.swordsman_layer_trial import weapon_image,placement_matrix

ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'game/assets/swordsman_v7_c6'
read=lambda p:json.loads(p.read_text(encoding='utf-8'))
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,d):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')

def main():
 p=argparse.ArgumentParser();p.add_argument('--source',type=Path,default=ROOT/'art/animations/players/swordsman/v7/sources/base_batch_c8/attack2_c1');args=p.parse_args();folder=args.source.resolve();assert folder.is_relative_to(ROOT)
 out=ROOT/'art/animations/players/swordsman/v7/exports/combo_keys_c8'/folder.name;review=ROOT/'docs/previews'/('v7_c8_'+folder.name+'_keys');out.mkdir(parents=True,exist_ok=True);review.mkdir(parents=True,exist_ok=True)
 cfg_path=folder/'body_config.json';cfg=read(cfg_path);assert assess(cfg_path,folder/'proportions.json')['passed'];bm=(folder/cfg['output_dir']/'manifest.json').resolve();m=read(bm);assert m['config_sha256']==sha(cfg_path);hands=read(folder/'hand_calibration.json');joints=read(folder/'joint_calibration.json');assert joints['reviewed'];heads={a['pose_id']:a['head']for a in read(folder/'proportions.json')['poses']};base=read(BASE/'manifest.json');textures={};frames=[];names=[]
 def layer(im):
  box=im.getchannel('A').getbbox()
  if not box:return {}
  cut=im.crop(box);file='layers/'+hashlib.sha256(str(cut.size).encode()+cut.tobytes()).hexdigest()+'.png';dest=out/file;dest.parent.mkdir(exist_ok=True)
  if not dest.exists():cut.save(dest)
  textures[file]={'file':file,'size':list(cut.size),'sha256':sha(dest)};return {'file':file,'rect':[box[0],box[1],box[2]-box[0],box[3]-box[1]]}
 weapons={};library_path=ROOT/'art/concepts/characters/players/swordsman/v7/weapon/grip_c8_c1/exports/manifest.json';library=read(library_path);weapon_sources={}
 for profile,spec in library['weapons'].items():
  source_path=ROOT/spec['file'];assert sha(source_path)==spec['sha256'];raw=Image.open(source_path).convert('RGBA');file='weapons/'+profile+'.png';dest=out/file;dest.parent.mkdir(exist_ok=True);raw.save(dest);textures[file]={'file':file,'size':list(raw.size),'sha256':sha(dest)};weapons[profile]=(raw,spec['marks'],spec['physical_blade_length']);weapon_sources[profile]=copy.deepcopy(spec);weapon_sources[profile]['file']=file
 for tick,source in enumerate(m['clips']['keys']['frames']):
  pid=source['source_pose'];name=pid.split('_')[-1];names.append(name);s=source['scale'];rx,ry=source['source_root'];point=lambda p:np.array([448+(p[0]-rx)*s,840+(p[1]-ry)*s]);crown=point(heads[pid]['hair_top']);chin=point(heads[pid]['chin']);primary=point(hands[pid]['primary']);secondary=point(hands[pid]['secondary']);u=primary-secondary;span=float(np.linalg.norm(u));u/=span;v=np.array([-u[1],u[0]])
  body=Image.open(bm.parent/source['file']).convert('RGBA');pixels=np.asarray(body);mask=Image.new('L',body.size);draw=ImageDraw.Draw(mask)
  for x,y in [primary,secondary]:draw.ellipse((x-9,y-9,x+9,y+9),fill=255)
  skin=(pixels[:,:,0]>150)&(pixels[:,:,1]>90)&(pixels[:,:,2]>65);alpha=np.asarray(mask).copy();alpha[~skin]=0;fingers=Image.composite(body,Image.new('RGBA',body.size),Image.fromarray(alpha));channel=Image.new('L',body.size);ImageDraw.Draw(channel).line([tuple(secondary-u*8),tuple(primary+u*8)],fill=255,width=5);clean=pixels.copy();clean[np.asarray(channel)>0,3]=0;body=Image.fromarray(clean)
  g={'head_center':((crown+chin)*.5).tolist(),'head_size':float(chin[1]-crown[1]),'head_angle':0.,'grip':primary.tolist(),'secondary_grip':secondary.tolist(),'root':[448,840],'joints':[point(p).tolist()for p in joints['points'][pid]]}
  if g['head_size']>54:
   target=copy.deepcopy(g);target['head_center'][1]+=(g['head_size']-54)*.5;target['head_size']=54;body,fingers,g=retarget(body,fingers,g,target)
  frame={'source_pose':pid,'start_tick':tick,'duration_ticks':1,'height_px':0,'root_dx':0,'body':layer(body),'fingers':layer(fingers),'motion_geometry':g,'grip_span':span,'profiles':{}}
  for profile,(raw,marks,length)in weapons.items():
   angle=math.atan2(u[1],u[0]);blade,sampling=weapon_image(raw,marks,(1024,1080),g['grip'],angle,length,(u,v));matrix,_=placement_matrix(marks,angle,length,(u,v));a,b,c,d=matrix
   def placed(mark):
    dx,dy=np.asarray(mark)-marks['grip'];return [float(g['grip'][0]+a*dx+b*dy),float(g['grip'][1]+c*dx+d*dy)]
   tip=placed(marks['tip']);assert tip[1]<=844,(name,profile,'blade below floor',tip)
   frame['profiles'][profile]={'front':layer(blade),'back':{},'grip':g['grip'],'guard':placed(marks['guard']),'tip':tip,'cutting_edge':placed(marks['cutting_edge']),'spine':placed(marks['spine']),'basis_u':u.tolist(),'basis_v':v.tolist(),'matrix':list(matrix),'physical_blade_length':length,'source_sampling_scale':sampling}
  frames.append(frame)
 manifest={'schema':'swordsman_runtime_layers/2','revision':cfg['revision']+'_layer_keys','fps':60,'native_canvas':[1024,1080],'anchor':[448,840],'clips':{'keys':{'semantic_id':cfg['clips']['keys']['asset_id'],'loop':False,'root_mode':'ground','duration_ticks':len(frames),'frames':frames}},'textures':textures,'weapon_sources':weapon_sources,'weapon_library':{'manifest':library_path.relative_to(ROOT).as_posix(),'sha256':sha(library_path)},'joint_order':joints['joint_order'],'base_manifest_sha256':sha(BASE/'manifest.json'),'source_inputs':{'config':cfg_path.relative_to(ROOT).as_posix(),'sha256':sha(cfg_path),'audit_sha256':sha(folder/'proportions.json'),'body_manifest':bm.relative_to(ROOT).as_posix(),'body_manifest_sha256':sha(bm),'hands_sha256':sha(folder/'hand_calibration.json'),'joints_sha256':sha(folder/'joint_calibration.json')},'coverage':{'complete':False,'reason':'static source pose rehang only; no inbetweens or action clock'},'authorization':{'runtime_trial_allowed':False,'gm_preview_allowed':False},'validation':{'source_G1_passed':True,'head_upscale':False,'source_keys':len(frames),'G2_approved':False,'G3_approved':False,'runtime_user_approved':False},'recipe':{f:sha(ROOT/'tools'/f)for f in ['bake_swordsman_combo_keys_c8.py','bake_swordsman_motion.py','actor_motion.py','explore/swordsman_layer_trial.py']}}
 write(out/'manifest.json',manifest)
 font=ImageFont.truetype('C:/Windows/Fonts/msyh.ttc',28)
 def actor(f,profile):
  image=Image.new('RGBA',(1024,1080));pf=f['profiles'][profile]if profile else None
  for ref in ([pf['back'],f['body'],pf['front'],f['fingers']]if pf else[f['body'],f['fingers']]):
   if ref:image.alpha_composite(Image.open(out/ref['file']).convert('RGBA'),tuple(ref['rect'][:2]))
  return image
 for name,f in zip(names,frames):
  scene=Image.new('RGBA',(2560,1440),'#252c35');draw=ImageDraw.Draw(scene);draw.line((0,1120,2560,1120),fill='#66727f',width=2);draw.text((60,60),name+' / 静态源姿势分层核对，非连续动作',font=font,fill='white')
  for x,profile,title in [(370,None,'裸动作'),(970,'katana','太刀'),(1570,'greatsword','巨剑'),(2170,'shortsword','短剑')]:
   painted=actor(f,profile);scene.alpha_composite(painted,(x-448,1120-840));draw.text((x-50,590),title,font=font,fill='white')
   # Crop the isolated actor, not the contact board: a neighbouring greatsword
   # can otherwise leak into this native-pixel inspection viewport.
   isolated=Image.new('RGBA',painted.size,'#252c35');isolated.alpha_composite(painted);ImageDraw.Draw(isolated).line((0,840,1024,840),fill='#66727f',width=2);isolated.crop((98,370,798,1020)).convert('RGB').save(review/(name+'_'+(profile or'body')+'_native.png'))
  scene.convert('RGB').save(review/(name+'_full_2k.png'))
 html='''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>第二刀源姿势分层核对</title><style>body{margin:24px;background:#171c24;color:#e5e9ef;font:16px system-ui}p{line-height:1.6;color:#b8c5d7}select{font:inherit;padding:8px;margin-right:12px}img{display:block;max-width:100%;max-height:75vh;margin-top:16px}</style><h2>第二刀：静态源姿势分层核对</h2><p>仅为蓄势、接触、余势三张真实源姿势；未制作完整连续动作，未接入游戏。G1通过；握持、刃口和身体发力尚待评审。各武器使用完全相同的身体/手指和时钟。局部图只裁切，没有放大。</p><select id="pose">__POSES__</select><select id="view"><option value="body_native">裸动作</option><option value="katana_native">太刀</option><option value="greatsword_native">巨剑</option><option value="shortsword_native">短剑</option><option value="full_2k">完整2K</option></select><img id="frame"><script>const p=document.querySelector('#pose'),v=document.querySelector('#view'),f=document.querySelector('#frame');function load(){f.src=p.value+'_'+v.value+'.png'}p.onchange=load;v.onchange=load;load()</script></html>'''.replace('__POSES__',''.join('<option value="'+n+'">'+n+'</option>'for n in names));(review/'index.html').write_text(html,encoding='utf-8',newline='\n')
 write(review/'review_manifest.json',{'package_sha256':sha(out/'manifest.json'),'source_keys':len(frames),'continuous_action':False,'runtime_installed':False,'review_files':{p.name:sha(p)for p in review.iterdir()if p.suffix in ['.png','.html']}});print('Static key rehang saved',review)

if __name__=='__main__':main()
