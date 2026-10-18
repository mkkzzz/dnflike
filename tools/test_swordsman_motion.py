"""Validate native dense motion, installed pixel identity and coupled weapons.

These tests cover contracts. Artwork and motion appeal still require playback.
"""
from pathlib import Path
import hashlib,json,math,unittest
import numpy as np
from PIL import Image
from actor_motion import controls,surface_map
from check_actor_proportions import assess
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'art/animations/players/swordsman/v7/exports/base_runtime_c6'
GAME=ROOT/'game/assets/swordsman_v7_c6'
read=lambda p:json.loads(p.read_text(encoding='utf-8'))
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()

class NativeMotionTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):cls.m=read(OUT/'manifest.json')
 def test_installed_package_is_the_actual_review_package(self):
  self.assertEqual((OUT/'manifest.json').read_bytes(),(GAME/'manifest.json').read_bytes())
  self.assertTrue(self.m['validation']['passed']);self.assertTrue(self.m['coverage']['complete'])
  self.assertFalse(self.m['validation']['artwork_approved']);self.assertFalse(self.m['validation']['runtime_user_approved'])
  for spec in self.m['textures'].values():
   for folder in [OUT,GAME]:
    self.assertEqual(sha(folder/spec['file']),spec['sha256'])
    with Image.open(folder/spec['file'])as image:self.assertEqual(list(image.size),spec['size'])
 def test_user_approved_idle_remains_exactly_the_reviewed_pixels_and_clock(self):
  approval=read(ROOT/'art/animations/players/swordsman/v7/sources/base_batch_c7/idle_approval.json')
  self.assertEqual(self.m['clips']['idle'],approval['clip'])
  for name,digest in approval['textures'].items():
   for folder in [OUT,GAME]:self.assertEqual(sha(folder/name),digest)
 def test_full_source_gates_precede_motion(self):
  for entry in self.m['source_inputs']:
   path=ROOT/entry['config'];self.assertEqual(sha(path),entry['sha256'])
   self.assertTrue(assess(path,path.parent/'proportions.json')['passed'])
   self.assertTrue(read(path.parent/'proportions.json')['landmark_semantics_reviewed'])
 def test_dense_clock_includes_loops_and_all_32_non_skill_actions(self):
  self.assertEqual(len(self.m['clips']),32)
  total=0
  for name,c in self.m['clips'].items():
   self.assertEqual(len(c['frames']),c['duration_ticks'])
   self.assertEqual([f['start_tick']for f in c['frames']],list(range(c['duration_ticks'])))
   self.assertTrue(all(f['duration_ticks']==1 for f in c['frames']))
   for f in c['frames']:
    g=f['motion_geometry'];self.assertTrue(53.7<=g['head_size']<=54.0001)
    self.assertLess(float(np.linalg.norm(np.asarray(g['root'])-[448,840])),1e-7);self.assertEqual(f['height_px'],0)
   if name in ['idle','walk','run','attack1','attack2','attack3','jump_land']:
    self.assertGreater(len({f['body']['file']for f in c['frames']}),c['duration_ticks']*.5)
   total+=len(c['frames'])
  self.assertEqual(total,self.m['validation']['dense_frames'])
 def test_weapon_marks_follow_one_exact_matrix_with_real_cutting_side(self):
  for name,c in self.m['clips'].items():
   for f in c['frames']:
    for profile,p in f['profiles'].items():
     spec=self.m['weapon_sources'][profile];marks=spec['marks'];a,b,c0,d=p['matrix'];grip=np.asarray(p['grip'])
     for key in ['guard','tip','cutting_edge','spine']:
      delta=np.asarray(marks[key])-marks['grip'];actual=grip+np.array([[a,b],[c0,d]])@delta
      self.assertLess(float(np.linalg.norm(actual-p[key])),1e-6)
     self.assertEqual(p['grip'],f['motion_geometry']['grip'])
     edge=np.asarray(p['cutting_edge'])-p['spine'];direction=np.asarray(p['edge_review']['authored_cutting_direction'])
     self.assertGreater(float(edge@direction),0)
     self.assertLessEqual(p['source_sampling_scale'],1.00001)
 def test_combo_direction_and_two_hands_share_the_projected_hilt(self):
  for name,start,end in [('attack1',7,13),('attack2',4,12)]:
   frames=self.m['clips'][name]['frames'];before=frames[start]['profiles']['katana']['basis_u'];after=frames[end]['profiles']['katana']['basis_u']
   self.assertGreater(before[0],.9)if name=='attack1'else self.assertLess(before[0],-.9)
   self.assertLess(after[0],-.9)if name=='attack1'else self.assertGreater(after[0],.9)
   for f in frames[start:end+1]:
    g=f['motion_geometry'];hands=np.asarray(g['grip'])-g['secondary_grip'];axis=np.asarray(f['profiles']['katana']['basis_u'])
    self.assertGreater(hands@axis,0);self.assertLess(abs(float(hands[0]*axis[1]-hands[1]*axis[0])),1e-5)
   for t in range(start+1,end):
    for profile in self.m['profiles']:
     p=frames[t]['profiles'][profile];prev=frames[t-1]['profiles'][profile];nxt=frames[t+1]['profiles'][profile]
     travel=(np.asarray(nxt['tip'])-nxt['grip'])-(np.asarray(prev['tip'])-prev['grip'])
     cutting=np.asarray(p['cutting_edge'])-p['spine']
     self.assertGreater(float(cutting@travel),0,'Actual texture edge must lead the active sweep')
  third=self.m['clips']['attack3']['frames'];self.assertLess(third[16]['motion_geometry']['grip'][1],third[6]['motion_geometry']['grip'][1]-50)
  self.assertTrue(self.m['combo_rising'])
 def test_landing_finishes_at_the_real_idle_pose(self):
  land=self.m['clips']['jump_land']['frames'];idle=self.m['clips']['idle']['frames'][0]
  self.assertEqual(land[-1]['body'],idle['body']);self.assertEqual(land[-1]['motion_geometry'],idle['motion_geometry'])
  ys=[f['motion_geometry']['head_center'][1]for f in land]
  self.assertGreater(ys[0]-ys[-1],40);self.assertLess(max(abs(b-a)for a,b in zip(ys,ys[1:])),25)
 def test_twohand_and_getup_dont_fade_large_body_regions(self):
  # This is a transparency regression, not an artistic motion approval.
  for name in ['attack1','attack2','attack3','getup']:
   for frame in self.m['clips'][name]['frames']:
    if not 0<frame['source_mix']<1:continue
    with Image.open(OUT/frame['body']['file'])as image:alpha=np.asarray(image.getchannel('A'))
    fraction=np.sum((alpha>32)&(alpha<240))/max(1,np.sum(alpha>32))
    self.assertLess(fraction,.10,f'{name} tick{frame["start_tick"]}: opaque body turned into a translucent overlap')
 def test_local_surface_keeps_native_identity_and_control_vertices(self):
  # Four corners plus a local grip: a grip edit must not affect a remote triangle.
  dst=np.array([[0,0],[64,0],[0,64],[64,64],[20,20]],float)/512
  mx,my=surface_map(dst,dst,(64,64));yy,xx=np.mgrid[:64,:64]
  self.assertLess(float(np.max(np.abs(mx-xx))),.001);self.assertLess(float(np.max(np.abs(my-yy))),.001)
  src=dst.copy();src[-1]+=[3/512,1/512];mx,my=surface_map(dst,src,(64,64))
  self.assertAlmostEqual(float(mx[20,20]),23,places=3);self.assertAlmostEqual(float(my[20,20]),21,places=3)
 def test_backend_is_audited_correspondence_and_not_rejected_dis(self):
  self.assertIn('RIFE 4.6',self.m['motion_backend']['name']);self.assertEqual(self.m['motion_backend']['license'],'MIT')
  self.assertEqual(self.m['motion_backend']['model_sha256']['flownet.bin'],'f334ed2260149ce0188a6dcf049844e8b0cdd912e01cbcfb63553157d2508958')

if __name__=='__main__':unittest.main()
