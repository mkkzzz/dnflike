"""Contract regressions for the real v7 layer trial and affine grip attachment."""
import copy
import json
import math
import tempfile
import unittest
from pathlib import Path
from PIL import Image,ImageDraw,ImageChops
from explore.swordsman_layer_trial import ROOT,bake,weapon_image,sha,edge_clear,projection_basis,placement_matrix

SOURCE=ROOT/'art/animations/players/swordsman/v7/sources/layer_trial_c3/attack1'
PACKAGE=ROOT/'art/animations/players/swordsman/v7/exports/layer_trial_c3'


class LayerTrialTests(unittest.TestCase):
    def fixture(self):
        image=Image.new('RGBA',(180,80));d=ImageDraw.Draw(image)
        d.rectangle((9,29,15,35),fill='#ff0000');d.rectangle((30,30,152,34),fill='white')
        return image,{'grip':[12,32],'guard':[32,32],'tip':[152,32]}

    def test_grip_and_quarter_turn_map_to_expected_pixels(self):
        image,marks=self.fixture()
        rendered,scale=weapon_image(image,marks,(400,400),(180,200),math.pi/2,60)
        self.assertEqual(scale,.5)
        self.assertGreater(rendered.getpixel((180,200))[0],180)
        self.assertGreater(rendered.getpixel((180,200))[3],180)
        self.assertGreater(rendered.getpixel((180,265))[3],128)
        self.assertEqual(rendered.getpixel((245,200))[3],0)

    def test_source_upscale_is_rejected(self):
        image,marks=self.fixture()
        with self.assertRaisesRegex(ValueError,'upscale'):
            weapon_image(image,marks,(400,400),(180,200),0,121)

    def test_canvas_clipping_is_rejected(self):
        image,marks=self.fixture()
        with self.assertRaisesRegex(ValueError,'edge'):
            weapon_image(image,marks,(400,400),(20,200),math.pi,60)

    def modified_config(self,change):
        config=json.loads((SOURCE/'layer_config.json').read_text(encoding='utf-8'))
        for key in ['output_dir','body_manifest','body_config','body_audit']:
            config[key]=str((SOURCE/config[key]).resolve())
        for weapon in config['weapons'].values():weapon['file']=str((SOURCE/weapon['file']).resolve())
        config['projection_guide']['file']=str((SOURCE/config['projection_guide']['file']).resolve())
        change(config)
        temp_root=(ROOT/'temp').resolve();temp_root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='layer_contract_',dir=temp_root) as folder:
            folder=Path(folder).resolve();self.assertTrue(folder.is_relative_to(temp_root))
            path=folder/'config.json';path.write_text(json.dumps(config),encoding='utf-8')
            return bake(path)

    def test_rejected_true_chin_revision_cannot_enter_layer_bake(self):
        def change(c):
            c['body_manifest']=str(ROOT/'art/animations/players/swordsman/v7/exports/layer_trial_c3_body_c2/manifest.json')
            c['body_config']=str(SOURCE/'body_config_c2.json');c['body_audit']=str(SOURCE/'proportions_body_c2.json')
        with self.assertRaisesRegex(ValueError,'proportion preflight'):
            self.modified_config(change)

    def test_changed_weapon_source_binding_is_rejected(self):
        with self.assertRaisesRegex(ValueError,'Weapon source hash'):
            self.modified_config(lambda c:c['weapons']['katana'].update(sha256='0'*64))

    def test_changed_projection_guide_is_rejected(self):
        with self.assertRaisesRegex(ValueError,'Projection guide hash'):
            self.modified_config(lambda c:c['projection_guide'].update(sha256='0'*64))

    def test_changed_body_pixels_are_rejected(self):
        with self.assertRaisesRegex(ValueError,'Body pixels changed'):
            self.modified_config(lambda c:c['poses']['attack1_01'].update(body_sha256='0'*64))

    def test_same_body_pixels_and_clock_are_shared_by_all_profiles(self):
        manifest=json.loads((PACKAGE/'manifest.json').read_text(encoding='utf-8'))
        self.assertEqual(manifest['duration_ticks'],30)
        self.assertEqual([f['duration_ticks'] for f in manifest['frames']],[3,5,1,2,1,10,8])
        for frame in manifest['frames']:
            self.assertEqual(sha(PACKAGE/frame['body']),frame['body_sha256'])
            self.assertEqual(set(frame['profiles']),{'katana','greatsword','shortsword'})
            self.assertEqual(frame['physical_katana_blade_length'],256)
            self.assertGreater(frame['trial_projected_katana_blade_length'],38.4)
            self.assertLessEqual(frame['trial_projected_katana_blade_length'],256.001)
            for profile in frame['profiles'].values():
                self.assertLessEqual(profile['source_sampling_scale'],1)
                self.assertEqual(profile['grip'],frame['hand'])
        self.assertFalse(manifest['artwork_approved'])
        self.assertFalse(manifest['integration_allowed'])

    def test_projected_length_and_width_do_not_shrink_together(self):
        _,marks=self.fixture()
        basis=projection_basis({'blade_dir':[.6,0,.8],'blade_edge':[0,-1,0]},{'yaw':0,'pitch':0},0)
        matrix,scale=placement_matrix(marks,0,60,basis)
        self.assertAlmostEqual(scale,.5)
        self.assertAlmostEqual(matrix[0],.3)
        self.assertAlmostEqual(matrix[3],.5)

    def test_unreviewed_edge_on_view_is_rejected(self):
        with self.assertRaisesRegex(ValueError,'Edge-on'):
            projection_basis({'blade_dir':[1,0,0],'blade_edge':[0,0,1]},{'yaw':0,'pitch':0},0)

    def test_recomposing_the_real_layers_matches_every_delivered_composite(self):
        manifest=json.loads((PACKAGE/'manifest.json').read_text(encoding='utf-8'))
        for frame in manifest['frames']:
            with Image.open(PACKAGE/frame['body']) as im:body=im.convert('RGBA')
            with Image.open(PACKAGE/frame['fingers']) as im:fingers=im.convert('RGBA')
            for profile in frame['profiles'].values():
                with Image.open(PACKAGE/profile['back']) as im:back=im.convert('RGBA')
                with Image.open(PACKAGE/profile['front']) as im:front=im.convert('RGBA')
                actual=Image.alpha_composite(Image.alpha_composite(Image.alpha_composite(back,body),front),fingers)
                with Image.open(PACKAGE/profile['composite']) as expected:
                    self.assertEqual(actual.tobytes(),expected.convert('RGBA').tobytes())
                self.assertTrue(edge_clear(actual))

    def test_foreground_fingers_actually_cover_weapon_pixels(self):
        manifest=json.loads((PACKAGE/'manifest.json').read_text(encoding='utf-8'))
        protected=0
        for frame in manifest['frames']:
            with Image.open(PACKAGE/frame['fingers']) as im:fingers=im.convert('RGBA')
            profile=frame['profiles']['katana']
            with Image.open(PACKAGE/profile['front']) as im:front=im.convert('RGBA')
            with Image.open(PACKAGE/profile['composite']) as im:final=im.convert('RGBA')
            overlap=ImageChops.multiply(fingers.getchannel('A'),front.getchannel('A')).getbbox()
            if not overlap:continue
            for y in range(overlap[1],overlap[3]):
                for x in range(overlap[0],overlap[2]):
                    if fingers.getpixel((x,y))[3]==255 and front.getpixel((x,y))[3]>128:
                        self.assertEqual(final.getpixel((x,y)),fingers.getpixel((x,y)))
                        protected+=1
        self.assertGreater(protected,10)

    def test_review_gif_clock_is_action_plus_declared_hold(self):
        for stem in ['three_weapons','three_weapons_left']:
            for suffix,expected in [('',800),('_slow3x',2400)]:
                with Image.open(PACKAGE/'previews'/(stem+suffix+'.gif')) as gif:
                    total=0
                    for index in range(gif.n_frames):
                        gif.seek(index);total+=gif.info.get('duration',0)
                self.assertEqual(total,expected)


if __name__=='__main__':unittest.main()
