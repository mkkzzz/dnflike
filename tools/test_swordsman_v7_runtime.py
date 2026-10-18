"""Reference-bound rolled heads and installed runtime package contracts."""
import copy,json,tempfile,unittest
from pathlib import Path
from check_actor_proportions import pose_span,digest
from review_swordsman_v7 import composite,PACKAGE,ROOT
from PIL import Image,ImageChops

class RolledHeadTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(dir=ROOT/'temp',prefix='roll_review_');self.addCleanup(self.temp.cleanup);self.folder=Path(self.temp.name)
  (self.folder/'evidence.png').write_bytes(b'fixture evidence')
  self.head={'hair_top':[20,30],'chin':[80,30],'projection':'reviewed_in_plane_roll'}
  self.profile={'schema':'actor_head_roll_review/1','source_sha256':'source','pose_id':'down','profile_sha256':'standard','head':self.head,'axis_down':[1,0],'perspective_scale':1,'landmark_semantics_reviewed':True,'evidence_file':'evidence.png','evidence_sha256':digest(self.folder/'evidence.png')}
 def check(self):
  path=self.folder/'profile.json';path.write_text(json.dumps(self.profile),encoding='utf-8')
  entry={'pose_id':'down','head':self.head,'projection_profile':{'file':'profile.json','sha256':digest(path)}}
  return pose_span(entry,'source',{'profile_sha256':'standard'},self.folder/'audit.json',ROOT,(200,200))
 def test_rotation_changes_measurement_axis_without_scaling_head(self):
  self.assertEqual(self.check(),60)
 def test_false_semantics_and_changed_source_cannot_pass(self):
  for key,value in [('landmark_semantics_reviewed',False),('source_sha256','other'),('profile_sha256','other')]:
   before=copy.deepcopy(self.profile);self.profile[key]=value
   with self.assertRaises(ValueError):self.check()
   self.profile=before
 def test_perspective_multiplier_and_invalid_axis_rejected(self):
  for scale in [1.1,True]:
   self.profile['perspective_scale']=scale
   with self.assertRaises(ValueError):self.check()
  self.profile['perspective_scale']=1
  for axis in [[0,0],[2,0],[float('nan'),0],[-1,0],[True,0]]:
   self.profile['axis_down']=axis
   with self.assertRaises(ValueError):self.check()
 def test_changed_visual_evidence_cannot_pass(self):
  (self.folder/'evidence.png').write_bytes(b'changed')
  with self.assertRaisesRegex(ValueError,'evidence'):self.check()

class RuntimePackageTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):cls.manifest=json.loads((PACKAGE/'manifest.json').read_text(encoding='utf-8'))
 def test_installed_manifest_is_identical_to_review_package(self):
  self.assertEqual((PACKAGE/'manifest.json').read_bytes(),(ROOT/'game/assets/swordsman_v7_c5/manifest.json').read_bytes())
  self.assertTrue(self.manifest['coverage']['complete']);self.assertEqual(len(self.manifest['clips']),32)
  self.assertFalse(self.manifest['authorization']['runtime_user_approved'])
 def test_runtime_trimmed_source_dimensions_and_sha_match(self):
  for spec in self.manifest['textures'].values():
   for folder in [PACKAGE,ROOT/'game/assets/swordsman_v7_c5']:
    self.assertEqual(digest(folder/spec['file']),spec['sha256'])
    with Image.open(folder/spec['file']) as image:self.assertEqual(list(image.size),spec['size'])
 def test_actual_cutting_side_has_positive_authored_alignment(self):
  for clip in self.manifest['clips'].values():
   for f in clip['frames']:
    for p in f['profiles'].values():
     direction=p['edge_review']['authored_cutting_direction']
     self.assertGreater(sum((a-b)*n for a,b,n in zip(p['cutting_edge'],p['spine'],direction)),0)
 def test_death_records_reuse_real_full_layers_in_order(self):
  c=self.manifest['clips']['death'];self.assertEqual([f['reused_from']for f in c['frames']],['hit_heavy','down','death_rest'])
  self.assertEqual([f['duration_ticks']for f in c['frames']],[6,8,28]);self.assertEqual(c['frames'][-1]['source_pose'],'death_2')

if __name__=='__main__':unittest.main()
