"""Actual exported gait pixels, foot contacts and source bindings."""
import unittest
import numpy as np
from PIL import Image
from test_swordsman_motion import ROOT,GAME,read,sha
from check_actor_proportions import assess
OUT=ROOT/'art/animations/players/swordsman/v7/exports/gait_rig_c8_pilot'

class GaitRigTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):cls.m=read(OUT/'manifest.json')
 def test_sources_are_bound_and_partial_pilot_cannot_auto_install(self):
  m=self.m;self.assertFalse(m['coverage']['complete']);self.assertFalse(m['authorization']['runtime_trial_allowed']);self.assertFalse(m['validation']['artwork_approved'])
  for e in m['source_inputs']:
   p=ROOT/e['config'];self.assertEqual(sha(p),e['sha256']);self.assertEqual(sha(p.parent/'proportions.json'),e['audit_sha256']);self.assertEqual(sha(ROOT/e['manifest']),e['manifest_sha256']);self.assertTrue(assess(p,p.parent/'proportions.json')['passed'])
  b=m['part_inputs'];self.assertEqual(sha(ROOT/b['calibration']),b['calibration_sha256'])
  cal=read(ROOT/b['calibration']);folder=(ROOT/b['calibration']).parent
  self.assertEqual(sha(folder/cal['arm']['file']),b['arm_source_sha256']);self.assertEqual(sha(folder/cal['leg_source']['file']),b['leg_source_sha256'])
  self.assertFalse(cal['leg_source']['same_scale_as_companion'])
  for f,h in m['recipe'].items():self.assertEqual(sha(ROOT/'tools'/f),h)
  frozen=read(folder.parent/'base_batch_c7/idle_approval.json');self.assertEqual(read(GAME/'manifest.json')['clips']['idle'],frozen['clip'])
  for f,h in frozen['textures'].items():self.assertEqual(sha(GAME/f),h)
 def test_real_rasters_keep_heads_knees_ankles_and_boots_visible(self):
  for spec in self.m['textures'].values():self.assertEqual(sha(OUT/spec['file']),spec['sha256'])
  for name,c in self.m['clips'].items():
   self.assertEqual(len(c['frames']),c['duration_ticks']);self.assertTrue(c['loop'])
   for tick,f in enumerate(c['frames']):
    self.assertEqual(f['start_tick'],tick);self.assertEqual(f['duration_ticks'],1);self.assertEqual(f['height_px'],0);self.assertLessEqual(f['motion_geometry']['head_size'],54.0001)
    alpha=Image.new('L',(1024,1080));ref=f['body'];alpha.paste(Image.open(OUT/ref['file']).getchannel('A'),tuple(ref['rect'][:2]));a=np.asarray(alpha)
    for label,p in [('head',f['motion_geometry']['head_center'])]+[(str(i),p)for i,p in enumerate(f['motion_geometry']['joints'])if i in [8,9,10,11]]:
     x,y=map(round,p);patch=a[y-8:y+9,x-8:x+9];self.assertGreater(int(np.sum(patch>=220)),20,f'{name} t{tick} {label} disappeared')
    self.assertLessEqual(alpha.getbbox()[3],843,f'{name} t{tick} crosses floor')
 def test_stance_matches_existing_world_speed_and_run_has_flight(self):
  evidence=read(OUT/'foot_contact_review.json');cal=read(ROOT/self.m['part_inputs']['calibration'])
  for name,rows in evidence['clips'].items():
   for row in rows:
    for foot in row['feet']:
     if foot['support']:self.assertAlmostEqual(foot['lowest_sole_y'],840,places=6)
     else:self.assertLessEqual(foot['lowest_sole_y'],840.00001)
   for side in ['near','far']:
    # Consecutive flat stance has a fixed world ankle; rotating heels/toes
    # still require a separate actual-pixel slipping review in the game.
    pairs=[]
    for a,b in zip(rows,rows[1:]):
     fa=next(v for v in a['feet']if v['side']==side);fb=next(v for v in b['feet']if v['side']==side)
     if fa['support']and fb['support']and fb['phase']>fa['phase']:pairs.append(abs(fb['world_ankle_x']-fa['world_ankle_x']))
    self.assertTrue(pairs);self.assertLess(max(pairs),1e-6)
   airborne=[r for r in rows if all(not f['support']for f in r['feet'])]
   self.assertTrue(airborne)if name=='run'else self.assertFalse(airborne)
   self.assertEqual(evidence['native_speed'][name],cal['motions'][name]['native_speed'])
 def test_independent_blades_are_native_and_stay_in_the_carrying_fist(self):
  for c in self.m['clips'].values():
   for f in c['frames']:
    for name,p in f['profiles'].items():
     self.assertEqual(p['grip'],f['motion_geometry']['grip']);self.assertLessEqual(p['source_sampling_scale'],1.00001)
     a,b,c0,d=p['matrix'];marks=self.m['weapon_sources'][name]['marks'];matrix=np.array([[a,b],[c0,d]])
     for key in ['tip','guard','cutting_edge','spine']:
      expected=np.asarray(p['grip'])+matrix@(np.asarray(marks[key])-marks['grip']);self.assertLess(float(np.linalg.norm(expected-p[key])),1e-6)

if __name__=='__main__':unittest.main()
