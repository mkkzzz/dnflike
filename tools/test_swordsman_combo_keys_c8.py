"""Independent weapon compatibility and actual source-key package checks."""
import copy,math,unittest
import numpy as np
from test_swordsman_motion import ROOT,read,sha
from explore.swordsman_layer_trial import placement_matrix
LIB=ROOT/'art/concepts/characters/players/swordsman/v7/weapon/grip_c8_c1/exports/manifest.json'
PACKAGE=ROOT/'art/animations/players/swordsman/v7/exports/combo_keys_c8/attack2_c1'
class ComboKeyTests(unittest.TestCase):
 def test_weapon_candidates_are_bound_to_real_sources_and_never_upscaled(self):
  m=read(LIB);folder=LIB.parent.parent
  self.assertFalse(m['authorization']['runtime_trial_allowed']);self.assertFalse(m['validation']['G3_approved'])
  self.assertEqual(sha(folder/'calibration.json'),m['calibration_sha256']);self.assertEqual(sha(ROOT/'tools/export_swordsman_grip_weapons_c8.py'),m['recipe_sha256'])
  for name,source in m['sources'].items():
   self.assertEqual(sha(ROOT/source['file']),source['sha256']);self.assertLessEqual(source['source_sampling_scale'],1);self.assertFalse(source['raster_upscaled']);self.assertEqual(sha(ROOT/m['weapons'][name]['file']),m['weapons'][name]['sha256'])
 def test_guard_tip_trajectories_match_existing_reach_for_affine_poses(self):
  old=read(ROOT/'game/assets/swordsman_v7_c6/manifest.json')['weapon_sources'];new=read(LIB)['weapons']
  for name,spec in new.items():
   before=old[name]
   self.assertEqual(before['physical_blade_length'],spec['physical_blade_length'])
   for angle in np.linspace(-math.pi,math.pi,25):
    for depth in [.22,.7,1.]:
     for edge_sign in [-1,1]:
      basis=([math.cos(angle),depth*math.sin(angle)],[-math.sin(angle)*edge_sign,math.cos(angle)*edge_sign]);points=[]
      for version in [before,spec]:
       matrix,_=placement_matrix(version['marks'],angle,version['physical_blade_length'],basis);matrix=np.array(matrix).reshape(2,2);points.append([matrix@(np.array(version['marks'][mark])-version['marks']['grip'])for mark in ['guard','tip']])
      np.testing.assert_allclose(points[0],points[1],atol=1e-8)
 def test_same_body_hands_fit_each_independent_handle_without_long_tail(self):
  m=read(PACKAGE/'manifest.json');self.assertEqual(sha(LIB),m['weapon_library']['sha256']);self.assertEqual(len(m['clips']['keys']['frames']),3)
  self.assertFalse(m['authorization']['runtime_trial_allowed']);self.assertFalse(m['validation']['G3_approved'])
  for frame in m['clips']['keys']['frames']:
   for name,spec in m['weapon_sources'].items():
    offset=spec['old_guard_offset_in_blade_basis'][0];tail=spec['actual_native_guard_to_pommel']-offset-frame['grip_span']
    self.assertGreaterEqual(tail,5,(name,frame['source_pose'],'pommel does not cover the secondary hand'));self.assertLessEqual(tail,18,(name,frame['source_pose'],'hilt extends into forearm'))
    np.testing.assert_allclose(frame['profiles'][name]['grip'],frame['motion_geometry']['grip'])
    u=np.array(frame['profiles'][name]['basis_u']);p=np.array(frame['motion_geometry']['grip']);q=np.array(frame['motion_geometry']['secondary_grip']);np.testing.assert_allclose(p-q,u*frame['grip_span'],atol=1e-6)
  for file,entry in m['textures'].items():self.assertEqual(sha(PACKAGE/file),entry['sha256'])
  for file,h in m['recipe'].items():self.assertEqual(sha(ROOT/'tools'/file),h)
 def test_rising_load_uses_real_clean_body_and_upward_cutting_edge(self):
  from check_actor_proportions import assess
  folder=ROOT/'art/animations/players/swordsman/v7/sources/base_batch_c8/attack3_load_c1';package=PACKAGE.parent/'attack3_load_c1';m=read(package/'manifest.json')
  self.assertTrue(assess(folder/'body_config.json',folder/'proportions.json')['passed']);self.assertEqual(m['clips']['keys']['duration_ticks'],1);self.assertFalse(m['authorization']['runtime_trial_allowed'])
  self.assertEqual(sha(folder/'body_config.json'),m['source_inputs']['sha256']);self.assertEqual(sha(folder/'proportions.json'),m['source_inputs']['audit_sha256']);self.assertEqual(sha(folder/'hand_calibration.json'),m['source_inputs']['hands_sha256'])
  frame=m['clips']['keys']['frames'][0];self.assertLessEqual(frame['motion_geometry']['head_size'],54.00001)
  for name,pose in frame['profiles'].items():
   edge=np.array(pose['cutting_edge'])-pose['spine'];self.assertLess(edge[1],0,(name,'blade must lead upward, source concept had wrong edge'));self.assertTrue(pose['edge_contract']['transverse_axis_reflected']);self.assertLessEqual(pose['source_sampling_scale'],1)
   self.assertLess(pose['tip'][1],840);source=m['weapon_sources'][name];matrix=np.array(pose['matrix']).reshape(2,2)
   for point in ['guard','tip','cutting_edge','spine']:np.testing.assert_allclose(np.array(pose['grip'])+matrix@(np.array(source['marks'][point])-source['marks']['grip']),pose[point],atol=1e-8)
  for file,entry in m['textures'].items():self.assertEqual(sha(package/file),entry['sha256'])
  for file,h in m['recipe'].items():self.assertEqual(sha(ROOT/'tools'/file),h)
if __name__=='__main__':unittest.main()
