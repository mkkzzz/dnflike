"""Crop/mask generated independent weapon candidates; preserve native reach.

Grip is derived from the old guard offset in blade-local space. Thus replacing
the raw texture cannot move the guard or tip for any existing affine pose.
No painted part is stretched or enlarged here.
"""
from pathlib import Path
import copy,hashlib,json,math
import numpy as np,cv2
from PIL import Image,ImageDraw
from explore.swordsman_layer_trial import placement_matrix
ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'art/concepts/characters/players/swordsman/v7/weapon/grip_c8_c1'
OUT=SOURCE/'exports'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
read=lambda p:json.loads(p.read_text(encoding='utf-8'))
def write(p,data):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
def main():
 cal=read(SOURCE/'calibration.json');base_path=ROOT/'game/assets/swordsman_v7_c6/manifest.json';base=read(base_path);weapons={};sources={}
 for name,entry in cal['weapons'].items():
  raw_path=SOURCE/entry['file'];raw=Image.open(raw_path).convert('RGBA');pixels=np.asarray(raw).copy();count,labels,stats,_=cv2.connectedComponentsWithStats((pixels[:,:,3]>32).astype('uint8'));assert count>1
  label=1+int(np.argmax(stats[1:,cv2.CC_STAT_AREA]));support=cv2.dilate((labels==label).astype('uint8'),np.ones((5,5),np.uint8));pixels[support==0,3]=0;clean=Image.fromarray(pixels);box=clean.getchannel('A').getbbox();image=clean.crop(box)
  old=base['weapon_sources'][name];marks=copy.deepcopy(entry['marks']);u=np.array(marks['tip'],dtype=float)-marks['guard'];source_length=float(np.linalg.norm(u));u/=source_length;v=np.array([-u[1],u[0]]);scale=old['physical_blade_length']/source_length;assert scale<=1
  old_matrix,_=placement_matrix(old['marks'],0,old['physical_blade_length']);old_offset=np.array(old_matrix).reshape(2,2)@(np.array(old['marks']['guard'])-old['marks']['grip'])
  marks['grip']=(np.array(marks['guard'])-np.c_[u,v]@old_offset/scale).tolist()
  native_hilt=float((np.array(marks['guard'])-entry['pommel'])@u*scale)
  marks={key:[float(p[0]-box[0]),float(p[1]-box[1])]for key,p in marks.items()}
  dest=OUT/(name+'.png');dest.parent.mkdir(parents=True,exist_ok=True);image.save(dest)
  weapons[name]={'file':dest.relative_to(ROOT).as_posix(),'marks':marks,'physical_blade_length':old['physical_blade_length'],'sha256':sha(dest),'actual_native_guard_to_pommel':native_hilt,'old_guard_offset_in_blade_basis':old_offset.tolist()}
  overlay=clean.copy();draw=ImageDraw.Draw(overlay)
  for key,p in marks.items():
   x,y=p[0]+box[0],p[1]+box[1];draw.ellipse((x-5,y-5,x+5,y+5),fill='#ff3fff');draw.text((x+7,y+7),key,fill='#ff3fff')
  overlay.save(SOURCE/(name+'_landmarks.png'))
  sources[name]={'file':raw_path.relative_to(ROOT).as_posix(),'sha256':sha(raw_path),'actual_size':list(raw.size),'requested_scene_native':[2560,1440],'raster_upscaled':False,'cleanup':'mask disconnected low-alpha fringe then crop; no paint deformation','crop':list(box),'source_sampling_scale':scale}
 result={'revision':'swordsman_c8_grip_c1','weapons':weapons,'sources':sources,'base_manifest_sha256':sha(base_path),'calibration_sha256':sha(SOURCE/'calibration.json'),'recipe_sha256':sha(Path(__file__)),'authorization':{'runtime_trial_allowed':False,'artwork_approved':False},'validation':{'G3_approved':False,'guard_tip_reach_preserved_by_construction':True}}
 write(OUT/'manifest.json',result);print({k:round(v['actual_native_guard_to_pommel'],2)for k,v in weapons.items()})
if __name__=='__main__':main()
