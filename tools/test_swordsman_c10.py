"""Contracts for the installed whole-body run/three-cut continuation."""
import hashlib,json,unittest
from pathlib import Path
import numpy as np
from PIL import Image
from check_actor_proportions import assess
R=Path(__file__).resolve().parents[1]
OUT=R/'art/animations/players/swordsman/v7/exports/run_combo_c10'
GAME=R/'game/assets/swordsman_v7_c10'
BASE=R/'game/assets/swordsman_v7_c6'
read=lambda p:json.loads(p.read_text(encoding='utf-8'))
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
class RunComboTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):cls.m=read(OUT/'manifest.json')
 def test_installed_review_package_is_identical_and_scoped(self):
  m=self.m;self.assertEqual(sha(OUT/'manifest.json'),sha(GAME/'manifest.json'))
  self.assertEqual(set(m['clips']),{'run','run_start','run_stop','attack1','attack2','attack3'})
  self.assertTrue(m['authorization']['runtime_trial_allowed']);self.assertFalse(m['validation']['runtime_user_approved'])
  self.assertEqual(m['runtime_overlay']['base_manifest_sha256'],sha(BASE/'manifest.json'))
  self.assertTrue(m['runtime_overlay']['preserve_approved_idle'])
  for p in m['textures'].values():
   for folder in [OUT,GAME]:self.assertEqual(sha(folder/p['file']),p['sha256'])
 def test_bound_source_proportions_native_pixels_and_recipes(self):
  m=self.m
  for item in m['source_inputs']:
   p=R/item['config'];self.assertEqual(sha(p),item['sha256']);self.assertEqual(sha(p.parent/'proportions.json'),item['audit_sha256'])
   self.assertEqual(sha(p.parent/'hand_calibration.json'),item['hand_sha256']);self.assertTrue(assess(p,p.parent/'proportions.json')['passed'])
   self.assertEqual(sha(R/item['body_manifest']),item['body_manifest_sha256'])
   for source in read(p)['sources'].values():self.assertLessEqual(380/source['standing_height'],1)
  for file,h in m['recipe'].items():self.assertEqual(sha(R/'tools'/file),h)
 def test_accepted_idle_and_other_clip_resources_are_unchanged(self):
  frozen=read(R/'art/animations/players/swordsman/v7/sources/base_batch_c7/idle_approval.json')
  self.assertEqual(read(BASE/'manifest.json')['clips']['idle'],frozen['clip'])
  for file,h in frozen['textures'].items():
   self.assertEqual(sha(BASE/file),h)
   if file in self.m['textures']:self.assertEqual(self.m['textures'][file]['sha256'],h)
  self.assertTrue(all(p.startswith('weapons_c10/')for p in [w['file']for w in self.m['weapon_sources'].values()]))
 def test_continuous_clocks_and_shared_body_weapon_geometry(self):
  for name,c in self.m['clips'].items():
   self.assertEqual(c['duration_ticks'],{'run':36,'run_start':9,'run_stop':10,'attack1':30,'attack2':32,'attack3':41}[name])
   self.assertEqual([f['start_tick']for f in c['frames']],list(range(c['duration_ticks'])))
   for f in c['frames']:
    self.assertEqual(f['duration_ticks'],1);self.assertIn('body',f);self.assertNotIn('body',f['profiles']['katana'])
    for profile,p in f['profiles'].items():
     self.assertEqual(p['grip'],f['motion_geometry']['grip']);self.assertLessEqual(p['tip'][1],844)
     self.assertLessEqual(p['source_sampling_scale'],1.000001)
     a,b,c_,d=p['matrix'];matrix=np.array([[a,b],[c_,d]]);marks=self.m['weapon_sources'][profile]['marks']
     for key in ['guard','tip','cutting_edge','spine']:
      actual=np.array(p['grip'])+matrix@(np.array(marks[key])-marks['grip'])
      self.assertLess(float(np.linalg.norm(actual-p[key])),1e-5)
 def test_blade_edges_follow_authored_cuts_and_trailing_run(self):
  for f in self.m['clips']['run']['frames']:
   for p in f['profiles'].values():self.assertGreater(p['cutting_edge'][1],p['spine'][1])
  for name,ticks in [('attack1',range(9,13)),('attack2',range(8,12)),('attack3',range(10,17))]:
   frames=self.m['clips'][name]['frames']
   for t in ticks:
    for profile in self.m['weapon_sources']:
     p=frames[t]['profiles'][profile];a=frames[t-1]['profiles'][profile];b=frames[t+1]['profiles'][profile]
     travel=(np.array(b['tip'])-b['grip'])-(np.array(a['tip'])-a['grip'])
     self.assertGreater(float((np.array(p['cutting_edge'])-p['spine'])@travel),0,(name,t,profile))
 def test_actual_native_capture_contains_all_requested_actions_and_facings(self):
  p=R/'docs/previews/v7_c10_run_combo/gameplay_native_2k.json';proof=read(p)
  self.assertEqual(proof['native_size'],[2560,1440]);self.assertFalse(proof['scaled']);self.assertEqual(proof['fps'],60)
  self.assertTrue(proof['lossless_native_rgb_verified']);self.assertEqual(proof['native_rgb_verified_frames'],proof['frames'])
  self.assertEqual(proof['movie_sha256'],sha(p.with_suffix('.mp4')))
  self.assertEqual(proof['packages']['c10_manifest_sha256'],sha(GAME/'manifest.json'))
  for name in ['run','run_start','run_stop','attack1','attack2','attack3']:
   active=[x for x in proof['timeline']if x['clip']==name]
   self.assertEqual({(x['profile'],x['facing'])for x in active},{(p,d)for p in ['katana','greatsword','shortsword']for d in [-1,1]},name)
  resolution=R/'docs/screenshots/v7_c10/1080p';small=read(resolution/'resolution_proof.json')
  self.assertEqual(small['size'],[1920,1080]);self.assertEqual(small['c10_manifest_sha256'],sha(GAME/'manifest.json'))
  self.assertEqual({x['actual_clip']for x in small['frames']},set(self.m['clips']))
  for f in small['frames']:
   self.assertEqual(f['requested'],f['actual_clip']);self.assertEqual(sha(resolution/f['file']),f['sha256'])
   with Image.open(resolution/f['file'])as im:self.assertEqual(im.size,(1920,1080))
if __name__=='__main__':unittest.main()
