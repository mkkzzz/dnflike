"""Package the representative first cut for an explicit GM preview only.

All other clips and the accepted idle continue to come from the installed c6
package. This partial package is deliberately ineligible for automatic loading.
"""
from pathlib import Path
import hashlib,json,shutil
from check_actor_proportions import assess

ROOT=Path(__file__).resolve().parents[1]
CANDIDATE=ROOT/'art/animations/players/swordsman/v7/exports/base_runtime_c8_c3'
OUT=ROOT/'art/animations/players/swordsman/v7/exports/first_cut_c8_trial'
GAME=ROOT/'game/assets/swordsman_v7_c8'
BASE=ROOT/'game/assets/swordsman_v7_c6'
read=lambda p:json.loads(p.read_text(encoding='utf-8'))
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,d):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')

def main():
 m=read(CANDIDATE/'manifest.json');base=read(BASE/'manifest.json')
 assert set(m['clips'])=={'attack1'} and not m['coverage']['complete']
 assert m['clips']['attack1']['duration_ticks']==base['clips']['attack1']['duration_ticks']==30
 frozen=read(ROOT/'art/animations/players/swordsman/v7/sources/base_batch_c7/idle_approval.json')
 assert base['clips']['idle']==frozen['clip']
 assert all(sha(BASE/p)==digest for p,digest in frozen['textures'].items())
 for file,digest in frozen['textures'].items():
  if file in m['textures']:assert m['textures'][file]['sha256']==digest,'Overlay must not shadow an accepted idle raster'
 for entry in m['source_inputs']:
  cfg=ROOT/entry['config'];assert sha(cfg)==entry['sha256'];assert sha(cfg.parent/'proportions.json')==entry['audit_sha256']
  assert assess(cfg,cfg.parent/'proportions.json')['passed']
  bm=(cfg.parent/read(cfg)['output_dir']/'manifest.json').resolve();assert sha(bm)==entry['manifest_sha256']
 for file,digest in m['recipe'].items():assert sha(ROOT/'tools'/file)==digest
 for spec in m['textures'].values():
  source=CANDIDATE/spec['file'];assert sha(source)==spec['sha256']
  target=OUT/spec['file'];target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,target)
 m['clips']['attack1']['root_mode']=base['clips']['attack1']['root_mode']
 m['revision']='v7_c8_first_cut_gm_trial'
 m['runtime_overlay']={'base_manifest_sha256':sha(BASE/'manifest.json'),'allowed_clips':['attack1'],'explicit_gm_only':True,'preserve_approved_idle':True}
 m['authorization']['gm_preview_allowed']=True
 m['authorization']['runtime_trial_allowed']=False
 m['authorization']['user_instruction']='2026-10-21 continue developing base actions and integration; this opt-in preview is not user artwork approval.'
 m['validation']['passed']=True
 m['candidate']={'manifest':(CANDIDATE/'manifest.json').relative_to(ROOT).as_posix(),'sha256':sha(CANDIDATE/'manifest.json'),'bake_cli':'python tools/bake_swordsman_recovery_c8.py --arm-controls --output art/animations/players/swordsman/v7/exports/base_runtime_c8_c3','packager_sha256':sha(Path(__file__))}
 write(OUT/'manifest.json',m)
 for source in [OUT/'manifest.json']+[OUT/spec['file']for spec in m['textures'].values()]:
  dest=GAME/source.relative_to(OUT);dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,dest)
 assert (OUT/'manifest.json').read_bytes()==(GAME/'manifest.json').read_bytes()
 print('First-cut GM trial installed; default c6 and accepted idle untouched')

if __name__=='__main__':main()
