"""Protect the partial GM trial's source, idle and replaceable-blade contracts."""
import unittest
import numpy as np
from test_swordsman_motion import ROOT,GAME,read,sha
from check_actor_proportions import assess

EXPORT=ROOT/'art/animations/players/swordsman/v7/exports/first_cut_c8_trial'
TRIAL=ROOT/'game/assets/swordsman_v7_c8'

class FirstCutTrialTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):cls.m=read(EXPORT/'manifest.json')
 def test_exact_package_is_opt_in_and_cannot_shadow_accepted_idle(self):
  m=self.m;self.assertEqual((EXPORT/'manifest.json').read_bytes(),(TRIAL/'manifest.json').read_bytes())
  self.assertFalse(m['coverage']['complete']);self.assertFalse(m['authorization']['runtime_trial_allowed'])
  self.assertTrue(m['authorization']['gm_preview_allowed']);self.assertEqual(set(m['clips']),{'attack1'})
  self.assertEqual(m['runtime_overlay']['base_manifest_sha256'],sha(GAME/'manifest.json'))
  self.assertFalse(m['validation']['artwork_approved']);self.assertFalse(m['validation']['G3_approved'])
  frozen=read(ROOT/'art/animations/players/swordsman/v7/sources/base_batch_c7/idle_approval.json')
  self.assertEqual(read(GAME/'manifest.json')['clips']['idle'],frozen['clip'])
  for name,digest in frozen['textures'].items():
   self.assertEqual(sha(GAME/name),digest)
   if name in m['textures']:self.assertEqual(m['textures'][name]['sha256'],digest)
  for spec in m['textures'].values():
   for folder in [EXPORT,TRIAL]:self.assertEqual(sha(folder/spec['file']),spec['sha256'])
 def test_bound_source_gates_and_reproducible_bake(self):
  m=self.m;self.assertEqual(len(m['source_inputs']),6)
  for entry in m['source_inputs']:
   cfg=ROOT/entry['config'];self.assertEqual(sha(cfg),entry['sha256'])
   self.assertEqual(sha(cfg.parent/'proportions.json'),entry['audit_sha256'])
   self.assertTrue(assess(cfg,cfg.parent/'proportions.json')['passed'])
   bm=(cfg.parent/read(cfg)['output_dir']/'manifest.json').resolve()
   self.assertEqual(sha(bm),entry['manifest_sha256'])
  for file,digest in m['recipe'].items():self.assertEqual(sha(ROOT/'tools'/file),digest)
  self.assertEqual(sha(ROOT/m['candidate']['manifest']),m['candidate']['sha256'])
  self.assertEqual(sha(ROOT/'tools/package_swordsman_c8_trial.py'),m['candidate']['packager_sha256'])
 def test_coupled_blades_keep_true_edge_forward_and_native_sampling(self):
  frames=self.m['clips']['attack1']['frames'];self.assertEqual(len(frames),30)
  for f in frames:
   self.assertEqual(f['duration_ticks'],1);self.assertLessEqual(f['motion_geometry']['head_size'],54.0001)
   for profile,p in f['profiles'].items():
    self.assertEqual(p['grip'],f['motion_geometry']['grip']);self.assertLessEqual(p['source_sampling_scale'],1.00001)
    source=self.m['weapon_sources'][profile];marks=source['marks'];a,b,c,d=p['matrix']
    for key in ['tip','guard','cutting_edge','spine']:
     actual=np.asarray(p['grip'])+np.array([[a,b],[c,d]])@(np.asarray(marks[key])-marks['grip'])
     self.assertLess(float(np.linalg.norm(actual-p[key])),1e-6)
   if 8<=f['start_tick']<13:
    hands=np.asarray(f['motion_geometry']['grip'])-f['motion_geometry']['secondary_grip'];u=f['profiles']['katana']['basis_u']
    self.assertLess(abs(float(hands[0]*u[1]-hands[1]*u[0])),1e-5);self.assertGreater(hands@u,0)
  for tick in range(9,13):
   for profile in self.m['weapon_sources']:
    p=frames[tick]['profiles'][profile];before=frames[tick-1]['profiles'][profile];after=frames[tick+1]['profiles'][profile]
    travel=(np.asarray(after['tip'])-after['grip'])-(np.asarray(before['tip'])-before['grip'])
    self.assertGreater(float((np.asarray(p['cutting_edge'])-p['spine'])@travel),0)
 def test_native_capture_really_exercises_all_profiles_and_facings(self):
  folder=ROOT/'docs/previews/v7_c8_trial';proof=read(folder/'first_cut_native_2k.json')
  self.assertEqual(proof['native_size'],[2560,1440]);self.assertEqual(proof['fps'],60);self.assertFalse(proof['scaled'])
  self.assertEqual(proof['movie_sha256'],sha(folder/'first_cut_native_2k.mp4'))
  self.assertEqual(proof['packages']['trial_manifest_sha256'],sha(TRIAL/'manifest.json'))
  active=[v for v in proof['timeline']if v['clip']=='attack1']
  self.assertEqual({(v['profile'],v['facing'])for v in active},{(p,d)for p in ['katana','greatsword','shortsword']for d in [-1,1]})
  self.assertEqual({int(v['clock'])for v in active},set(range(30)))

if __name__=='__main__':unittest.main()
