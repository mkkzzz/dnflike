"""Install the authorized six-clip C10 overlay, retaining accepted idle and c6 rollback."""
from pathlib import Path
import json,hashlib,shutil
from check_actor_proportions import assess
ROOT=Path(__file__).resolve().parents[1]
CANDIDATE=ROOT/'art/animations/players/swordsman/v7/exports/run_combo_c10'
GAME=ROOT/'game/assets/swordsman_v7_c10'
BASE=ROOT/'game/assets/swordsman_v7_c6'
ALLOWED=['run','run_start','run_stop','attack1','attack2','attack3']
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
read=lambda p:json.loads(p.read_text(encoding='utf-8'))
def main():
 m=read(CANDIDATE/'manifest.json');base=read(BASE/'manifest.json')
 assert set(m['clips'])==set(ALLOWED)and m['validation']['passed']and m['authorization']['runtime_trial_allowed']
 frozen=read(ROOT/'art/animations/players/swordsman/v7/sources/base_batch_c7/idle_approval.json')
 assert base['clips']['idle']==frozen['clip']
 for file,h in frozen['textures'].items():
  assert sha(BASE/file)==h
  if file in m['textures']:assert m['textures'][file]['sha256']==h,'Overlay shadows approved idle'
 for entry in m['source_inputs']:
  c=ROOT/entry['config'];assert sha(c)==entry['sha256'];assert sha(c.parent/'proportions.json')==entry['audit_sha256'];assert assess(c,c.parent/'proportions.json')['passed'];assert sha(c.parent/'hand_calibration.json')==entry['hand_sha256'];assert sha(ROOT/entry['body_manifest'])==entry['body_manifest_sha256']
 for file,h in m['recipe'].items():assert sha(ROOT/'tools'/file)==h
 approval=ROOT/'art/animations/players/swordsman/v7/sources/whole_body_gait_c9/run_motion_c5/direction_approval.json'
 assert read(approval)['status']=='motion_direction_approved'
 for name,c in m['clips'].items():
  if name!='run':assert c['duration_ticks']==base['clips'][name]['duration_ticks']
  c['weapon_set']='c10'
 m['runtime_overlay']={'base_manifest_sha256':sha(BASE/'manifest.json'),'allowed_clips':ALLOWED,'default_enabled':True,'preserve_approved_idle':True,'whole_person_body_sources':True}
 m['authorization']['direction_approval']={'file':approval.relative_to(ROOT).as_posix(),'sha256':sha(approval)}
 m['packager_sha256']=sha(Path(__file__))
 # The immutable source candidate remains the exact offline/runtime review package.
 (CANDIDATE/'manifest.json').write_text(json.dumps(m,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
 for file in ['manifest.json']+list(m['textures']):
  p=CANDIDATE/file;target=GAME/file;target.parent.mkdir(parents=True,exist_ok=True)
  if file!='manifest.json':assert sha(p)==m['textures'][file]['sha256']
  shutil.copyfile(p,target)
 assert sha(CANDIDATE/'manifest.json')==sha(GAME/'manifest.json')
 print('Installed C10 run/start/stop and all three ground cuts; accepted idle preserved.')
if __name__=='__main__':main()
