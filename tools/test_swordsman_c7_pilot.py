"""Pilot contracts, including the observed missing-head regression.

Source direction approval is not G3 or complete motion artwork approval.
"""
import hashlib,json,unittest
from pathlib import Path
import numpy as np
from PIL import Image
from check_actor_proportions import assess

ROOT=Path(__file__).resolve().parents[1]
PACKAGE=ROOT/'art/animations/players/swordsman/v7/exports/base_runtime_c7_pilot_c5'
read=lambda p:json.loads(p.read_text(encoding='utf-8'))
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()

class FirstCutPilotTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):cls.m=read(PACKAGE/'manifest.json');cls.frames=cls.m['clips']['attack1']['frames']
 def test_sources_bound_to_all_reviewed_native_gates(self):
  self.assertEqual(len(self.m['source_inputs']),4)
  for entry in self.m['source_inputs']:
   config=ROOT/entry['config'];self.assertEqual(sha(config),entry['sha256']);self.assertTrue(assess(config,config.parent/'proportions.json')['passed'])
   self.assertEqual(sha(config.parent/'proportions.json'),entry['audit_sha256'])
   bm=(config.parent/read(config)['output_dir']/'manifest.json').resolve();self.assertEqual(sha(bm),entry['manifest_sha256'])
 def test_pilot_cannot_be_installed_as_a_complete_package(self):
  self.assertFalse(self.m['coverage']['complete']);self.assertFalse(self.m['authorization']['runtime_trial_allowed']);self.assertFalse(self.m['validation']['artwork_approved']);self.assertEqual(len(self.frames),30)
  review=read(PACKAGE/'visual_review.json');self.assertEqual(review['status'],'rejected');self.assertEqual(review['package_sha256'],sha(PACKAGE/'manifest.json'))
 def test_head_keeps_opaque_interior_while_following_the_body(self):
  yy,xx=np.mgrid[:1080,:1024];centers=[]
  for frame in self.frames:
   image=Image.new('RGBA',(1024,1080));ref=frame['body'];image.alpha_composite(Image.open(PACKAGE/ref['file']).convert('RGBA'),tuple(ref['rect'][:2]));g=frame['motion_geometry'];x,y=g['head_center'];h=g['head_size'];centers.append([x,y])
   core=((xx-x)/(h*.30))**2+((yy-y)/(h*.32))**2<1
   self.assertGreater(float((np.asarray(image)[:,:,3][core]>128).mean()),.8,'Head erased at tick '+str(frame['start_tick']))
   self.assertLessEqual(h,54.0001)
  span=np.ptp(np.array(centers),axis=0);self.assertGreater(span[0],30);self.assertGreater(span[1],40)
 def test_weapon_edge_grip_and_floor_for_all_three_real_blades(self):
  for profile in ['katana','greatsword','shortsword']:
   for frame in self.frames:
    blade=frame['profiles'][profile];self.assertLessEqual(blade['tip'][1],844);self.assertLessEqual(blade['source_sampling_scale'],1.0001)
    self.assertEqual(blade['grip'],frame['motion_geometry']['grip'])
   for tick in range(9,13):
    a=self.frames[tick-1]['profiles'][profile];b=self.frames[tick]['profiles'][profile]
    travel=np.asarray(b['tip'])-a['tip'];edge=np.asarray(b['cutting_edge'])-b['spine'];self.assertGreater(float(travel@edge),0,(profile,tick))
 def test_explicit_recovery_key_and_return_to_accepted_idle(self):
  self.assertEqual(self.frames[20]['source_pose'],'c7_attack1_recover')
  original=read(ROOT/'game/assets/swordsman_v7_c6/manifest.json')['clips']['idle']['frames'][0]
  for index in [0,29]:self.assertEqual(self.frames[index]['motion_geometry'],original['motion_geometry'])

if __name__=='__main__':unittest.main()
