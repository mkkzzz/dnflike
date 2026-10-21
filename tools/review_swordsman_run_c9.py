"""Static whole-body C9 carry pose with three independent weapon layers."""
from pathlib import Path
import argparse,hashlib,json,math
import numpy as np
from PIL import Image,ImageDraw
from check_actor_proportions import preflight
from explore.swordsman_layer_trial import weapon_image,placement_matrix,cutting_edge_basis
R=Path(__file__).resolve().parents[1]
B=R/'art/animations/players/swordsman/v7/sources/whole_body_gait_c9/run_compression_near_c1'
K=R/'art/animations/players/swordsman/v7/exports/whole_body_run_c9_key'
O=R/'art/animations/players/swordsman/v7/exports/whole_body_run_c9_layers'
V=R/'docs/previews/v7_c9_whole_body'
read=lambda p:json.loads(p.read_text(encoding='utf-8'))
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,v):p.write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
def main():
 global B,K,O
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--candidate',choices=['c1','c3'],default='c3')
 args=parser.parse_args()
 suffix='' if args.candidate=='c1' else '_c3'
 if args.candidate=='c3':
  B=B.parent/'run_drag_grip_c3';K=K.with_name(K.name+'_c3');O=O.with_name(O.name+'_c3')
 cfg=read(B/'body_config.json');gate=preflight(B/'body_config.json',cfg);m=read(K/'manifest.json');assert m['config_sha256']==sha(B/'body_config.json')
 h=read(B/'hand_calibration.json');assert h['reviewed'] and h['source_sha256']==sha(B/'body_c1.png')
 f=m['clips']['keys']['frames'][0];body=Image.open(K/f['file']).convert('RGBA');s=f['scale'];rx,ry=f['source_root']
 def point(p):return [448+(p[0]-rx)*s,840+(p[1]-ry)*s]
 grip=point(h['primary']);mask=Image.new('L',body.size);ImageDraw.Draw(mask).polygon([tuple(point(p))for p in h['finger_region']],fill=255)
 rgba=np.array(body);a=np.array(mask)
 if h.get('occlusion_mode','skin_only')=='skin_only':
  skin=(rgba[:,:,0]>150)&(rgba[:,:,1]>90)&(rgba[:,:,2]>65);a[~skin]=0
 fingers=Image.composite(body,Image.new('RGBA',body.size),Image.fromarray(a))
 O.mkdir(parents=True,exist_ok=True);V.mkdir(parents=True,exist_ok=True);body.save(O/'body.png');fingers.save(O/'fingers.png')
 assert np.array_equal(np.array(body),np.array(Image.open(K/f['file']))),'Whole body must remain pixel-identical'
 library=R/'art/concepts/characters/players/swordsman/v7/weapon/grip_c8_c1/exports/manifest.json';lib=read(library);profiles={}
 def preview(im,name):
  stage=Image.new('RGBA',im.size,'#222a31');stage.alpha_composite(im);ImageDraw.Draw(stage).line((0,840,1024,840),fill='#596875');stage.crop((0,470,700,880) if suffix else (0,330,700,980)).convert('RGB').save(V/('run'+suffix+'_'+name+'.png'))
 preview(body,'body')
 for name,spec in lib['weapons'].items():
  p=R/spec['file'];assert sha(p)==spec['sha256'];raw=Image.open(p).convert('RGBA');marks=spec['marks'];length=spec['physical_blade_length']
  u=np.array(h['blade_axis'],dtype=float);u/=np.linalg.norm(u);v=np.array([-u[1],u[0]])
  basis,edge=cutting_edge_basis(([float(x)for x in u],[float(x)for x in v]),marks,h['cutting_direction']);angle=math.atan2(u[1],u[0])
  weapon,sampling=weapon_image(raw,marks,body.size,grip,angle,length,basis);assert sampling<=1
  weapon.save(O/(name+'.png'));im=body.copy();im.alpha_composite(weapon);im.alpha_composite(fingers);preview(im,name)
  matrix,_=placement_matrix(marks,angle,length,basis);aa,bb,cc,dd=matrix
  def placed(mark):
   dx,dy=np.array(mark)-marks['grip'];return [float(grip[0]+aa*dx+bb*dy),float(grip[1]+cc*dx+dd*dy)]
  tip=placed(marks['tip']);assert tip[1]<840
  profiles[name]={'layer':name+'.png','sha256':sha(O/(name+'.png')),'source_sha256':sha(p),'grip':grip,'guard':placed(marks['guard']),'tip':tip,'cutting_edge':placed(marks['cutting_edge']),'spine':placed(marks['spine']),'cutting_edge_contract':edge,'physical_blade_length':length,'sampling_scale':sampling}
 write(O/'manifest.json',{'schema':'whole_body_carry_review/1','body':{'file':'body.png','sha256':sha(O/'body.png'),'unchanged_from_key_export':True},'fingers':{'file':'fingers.png','sha256':sha(O/'fingers.png')},'source_key_manifest_sha256':sha(K/'manifest.json'),'hand_calibration_sha256':sha(B/'hand_calibration.json'),'weapon_library_sha256':sha(library),'profiles':profiles,'layer_order':['body','weapon','fingers'],'source_G1':gate,'recipe_sha256':sha(Path(__file__)),'continuous_action':False,'runtime_installed':False,'G2_approved':False,'G3_approved':False,'source_pose_note':'Forward leaning carry/contact direction study; not a validated running compression phase.'})
 print(O/'manifest.json')
if __name__=='__main__':main()
