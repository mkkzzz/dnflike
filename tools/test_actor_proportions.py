"""Policy regressions: neutral calibration, every pose, real drift, stale data and legacy escape."""
import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from PIL import Image, ImageDraw

from check_actor_proportions import assess, digest, legacy_rebuild, preflight

ROOT=Path(__file__).resolve().parents[1]


class ProportionGateTests(unittest.TestCase):
    def setUp(self):
        base=(ROOT/'temp').resolve()
        base.mkdir(exist_ok=True)
        self.temp=tempfile.TemporaryDirectory(prefix='proportion_tests_',dir=base)
        self.folder=Path(self.temp.name).resolve()
        # Verify the recursive TemporaryDirectory cleanup stays under workspace temp.
        self.assertTrue(self.folder.is_relative_to(base))
        self.addCleanup(self.temp.cleanup)
        self.relative=lambda p:p.relative_to(ROOT).as_posix()
        ref=Image.new('RGBA',(120,800))
        ImageDraw.Draw(ref).rectangle((10,0,100,799),fill='white')
        ref.save(self.folder/'ref.png')
        sheet=Image.new('RGBA',(320,800))
        draw=ImageDraw.Draw(sheet)
        draw.rectangle((10,0,100,799),fill='white')
        draw.rectangle((160,100,250,550),fill='white')
        sheet.save(self.folder/'sheet.png')
        self.head=lambda x,y,h:{'hair_top':[x,y],'chin':[x,y+h],'projection':'upright_head'}
        self.profile={'references':[{'id':'ref','file':self.relative(self.folder/'ref.png'),
            'sha256':digest(self.folder/'ref.png'),'standing_top_y':0,'standing_bottom_y':800,'head':self.head(50,0,120)}],
            'max_head_scale_error_fraction':.08,'max_neutral_height_error_fraction':.02,'min_new_target_standing_height':380}
        self.config={'target_standing_height':380,'sources':{'a':{'file':'sheet.png','standing_height':800}},
            'clips':{'run':{'poses':[{'id':'crouch','source':'a','crop_bbox':[140,80,280,600]}]}}}
        self.audit={'config':self.relative(self.folder/'config.json'),
            'profile':self.relative(self.folder/'profile.json'),
            'sources':{'a':{'sha256':digest(self.folder/'sheet.png'),'scale_basis':{
                'kind':'same_sheet_neutral_companion','standing_top_y':0,'standing_bottom_y':800,
                'sole':[50,799],'crop_bbox':[0,0,120,800],
                'head':self.head(50,0,120)}}},
            'poses':[{'source':'a','pose_id':'crouch','head':self.head(200,100,120),'uncertainty_px':2}]}
        self.save()

    def save(self):
        def write(name,obj):
            (self.folder/name).write_text(json.dumps(obj),encoding='utf-8')
        write('profile.json',self.profile)
        self.audit['profile_sha256']=digest(self.folder/'profile.json')
        write('config.json',self.config)
        write('audit.json',self.audit)

    def check(self):
        self.save()
        return assess(self.folder/'config.json',self.folder/'audit.json')

    def test_crouch_does_not_change_anatomical_scale(self):
        result=self.check()
        self.assertTrue(result['passed'],result['failures'])
        self.assertAlmostEqual(result['measurements'][0]['head_output_px'],57)

    def test_twenty_percent_head_growth_is_rejected(self):
        self.audit['poses'][0]['head']=self.head(200,100,144)
        result=self.check()
        self.assertIn('head_scale_out_of_range:crouch',result['failures'])

    def test_crouch_bbox_cannot_replace_neutral_height(self):
        self.config['sources']['a']['standing_height']=450
        self.assertIn('standing_height_disagrees_with_neutral:a',self.check()['failures'])

    def test_missing_pose_annotation_is_rejected(self):
        pose=copy.deepcopy(self.config['clips']['run']['poses'][0]);pose['id']='second'
        self.config['clips']['run']['poses'].append(pose)
        self.assertIn('missing_pose_annotations',self.check()['failures'])

    def test_source_change_invalidates_annotations(self):
        with Image.open(self.folder/'sheet.png') as im:
            changed=im.copy()
        changed.putpixel((20,20),(255,0,0,255));changed.save(self.folder/'sheet.png')
        self.assertIn('source_hash_mismatch:a',self.check()['failures'])

    def test_profile_change_requires_new_binding(self):
        (self.folder/'profile.json').write_text(json.dumps({**self.profile,'note':'changed'}),encoding='utf-8')
        result=assess(self.folder/'config.json',self.folder/'audit.json')
        self.assertIn('profile_hash_mismatch',result['failures'])

    def test_upscale_is_rejected(self):
        self.config['target_standing_height']=900
        self.assertIn('upscale_forbidden:a',self.check()['failures'])

    def test_annotations_cannot_point_to_other_cell(self):
        self.audit['poses'][0]['head']=self.head(50,0,120)
        self.assertIn('head_landmark_outside_pose_crop:crouch',self.check()['failures'])

    def test_landmarks_cannot_point_to_transparent_background(self):
        self.audit['poses'][0]['head']=self.head(150,100,120)
        self.assertIn('head_landmark_not_visible:crouch',self.check()['failures'])

    def test_neutral_height_must_end_at_a_visible_sole(self):
        self.audit['sources']['a']['scale_basis']['sole']=[115,799]
        self.assertIn('neutral_sole_not_visible:a',self.check()['failures'])

    def test_mask_cannot_remove_a_head_that_passed_source_measurement(self):
        with Image.open(self.folder/'sheet.png') as im:changed=im.copy()
        draw=ImageDraw.Draw(changed)
        draw.rectangle((160,100,250,550),fill=(0,0,0,0))
        draw.rectangle((160,100,250,220),fill='white')
        draw.rectangle((160,250,250,550),fill='white')
        changed.save(self.folder/'sheet.png')
        self.audit['sources']['a']['sha256']=digest(self.folder/'sheet.png')
        self.config.update({'revision':'mask_fixture','output_dir':'out','canvas':[1024,800],
                            'anchor':[448,720],'proportion_check':'audit.json'})
        self.config['clips']['run'].update({'asset_id':'actor.test','loop':True,'root_mode':'ground'})
        self.config['clips']['run']['poses'][0].update({'root':[200,550],'foot':[200,550],'duration_ticks':4,
            'component_seed':[200,400],'component_padding':0,'alpha_core_threshold':24})
        self.save()
        result=subprocess.run([sys.executable,str(ROOT/'tools/explore/standard_actions_pilot.py'),
                               str(self.folder/'config.json')],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('proportion_hair_top',result.stderr)
        self.assertFalse((self.folder/'out').exists())

    def test_verified_candidate_can_export_with_gate_evidence(self):
        self.config.update({'revision':'verified_fixture','output_dir':'out','canvas':[1024,800],
                            'anchor':[448,720],'proportion_check':'audit.json'})
        self.config['clips']['run'].update({'asset_id':'actor.test','loop':True,'root_mode':'ground'})
        self.config['clips']['run']['poses'][0].update({'root':[200,550],'foot':[200,550],'duration_ticks':4})
        self.save()
        result=subprocess.run([sys.executable,str(ROOT/'tools/explore/standard_actions_pilot.py'),
                               str(self.folder/'config.json')],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        manifest=json.loads((self.folder/'out/manifest.json').read_text(encoding='utf-8'))
        self.assertTrue(manifest['proportion_gate']['passed'])
        self.assertEqual(manifest['target_standing_height'],380)

    def test_unmeasured_future_export_creates_no_files(self):
        target=self.folder/'must_not_exist'
        config={'revision':'fixture','output_dir':str(target)}
        path=self.folder/'no_audit.json';path.write_text(json.dumps(config),encoding='utf-8')
        result=subprocess.run([sys.executable,str(ROOT/'tools/explore/standard_actions_pilot.py'),str(path)],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('Missing mandatory proportion_check',result.stderr)
        self.assertFalse(target.exists())

    def test_legacy_escape_cannot_exempt_copied_config(self):
        original=ROOT/'art/animations/players/swordsman/v7/sources/pilot_c2.json'
        self.assertFalse(legacy_rebuild(original)['integration_allowed'])
        copy_path=self.folder/'copied_c2.json';copy_path.write_bytes(original.read_bytes())
        with self.assertRaisesRegex(ValueError,'exact archived config paths'):
            legacy_rebuild(copy_path)
        with self.assertRaisesRegex(ValueError,'Missing mandatory'):
            preflight(original,json.loads(original.read_text(encoding='utf-8')))


if __name__=='__main__':
    unittest.main()
