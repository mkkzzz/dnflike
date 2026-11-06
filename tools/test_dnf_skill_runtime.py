"""Catalog/asset integrity and specific adapter regressions, not fidelity certification."""
import json
import hashlib
import unittest
from unittest.mock import patch
import build_dnf_skill_runtime as builder
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "game_dnf/data/skill_runtime.json"
PACK = ROOT / "game_dnf/assets_local/content/combat_content.json"
COMBAT= ROOT / "game_dnf/assets_local/combat/manifest.json"


class SkillRuntimeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.runtime = json.loads(RUNTIME.read_text(encoding="utf-8"))
        cls.pack = json.loads(PACK.read_text(encoding="utf-8"))
        cls.skills = cls.runtime["skills"]
        cls.moves = cls.runtime["moves"]

    def test_every_tree_node_has_a_runtime_definition(self):
        self.assertEqual(self.runtime["schema"], "dnf_skill_runtime/1")
        self.assertEqual(self.runtime["skill_count"], 175)
        self.assertEqual(self.runtime["tree_skill_count"], 78)
        self.assertEqual(self.runtime["tree_active_count"], 52)
        self.assertEqual(self.runtime["tree_passive_count"], 26)
        self.assertEqual(self.runtime["active_count"], 74)
        self.assertEqual(self.runtime["passive_count"], 101)
        self.assertEqual(len(self.skills), 175)
        self.assertEqual(len({skill["source_id"] for skill in self.skills.values()}), 175)

    def test_every_active_node_has_a_runtime_entry(self):
        for skill_id, skill in self.skills.items():
            if not skill["active"]:
                continue
            self.assertIn(skill_id, self.moves, skill_id)
            move = self.moves[skill_id]
            hits = sum(len(stage.get("hits", [])) for stage in move.get("stages", []))
            self.assertTrue(hits > 0 or move.get("effect_id") or move.get("movement"), skill_id)

    def test_backstep_dispatches_movement_without_a_fake_buff(self):
        move = self.moves["backstep"]
        self.assertEqual(move.get("movement"), "backstep")
        self.assertNotIn("effect_id", move)
        self.assertEqual(move["stages"][0]["ani"], "jump")

    def test_back_critical_uses_conditional_source_level_columns(self):
        for kind in ("physical", "magical"):
            skill = self.skills[kind+"backattackcritical"]
            record = self.pack["records"][skill["source_path"]]["decoded"]
            self.assertEqual(record["level_info"][:3], [1, 15, 30])
            self.assertEqual(skill["passive"], [{"stat": kind+"_back_crit", "op": "add", "level_row": 0, "scale": 0.001}])

    def test_normalwave_has_no_borrowed_upper_slash_damage_or_visual(self):
        move = self.moves["normalwave"]
        hits = [hit for stage in move["stages"] for hit in stage.get("hits", [])]
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0]["object"], "passiveobject/character/swordman/normalwave.obj")
        for stage in move["stages"]:
            for fx in stage.get("fx", []):
                self.assertNotIn("upperslash", self.runtime["assets"]["effect_anims"][fx["key"]])

    def test_blank_frames_are_not_missing_image_paths(self):
        class Library:
            def animation(self, path):
                return {"metadata": {"frames": [{"img": None}, {"img": path}]}}
        with patch.object(builder, "image_exists", side_effect=lambda _, path: path == "valid.img") as lookup:
            self.assertTrue(builder.safe_animation(Library(), "valid.img"))
            self.assertFalse(builder.safe_animation(Library(), "missing.img"))
            self.assertFalse(builder.safe_animation(Library(), "weapon%02d.img"))
            self.assertNotIn("None", [call.args[1] for call in lookup.call_args_list])

    def test_ice_fire_wave_casts_bind_verified_source_effects(self):
        manifest = json.loads(COMBAT.read_text(encoding="utf8"))
        for key, effect, recovery in [("icewave", "icewave.ani", 1), ("firewave", "firewavebig-sword-effect.ani", 0)]:
            move = self.moves[key]
            stage = move["stages"][0]
            self.assertEqual(move["native_state"], "wave_cast")
            self.assertEqual(move["native_recovery_col"], recovery)
            self.assertEqual(stage["ani"], "wave")
            self.assertEqual(len(stage["hits"]), 1)  # No pixel-derived caster damage.
            self.assertEqual(stage["hits"][0]["at"], 10150)
            self.assertNotIn("derived", stage["hits"][0])
            fx = stage["fx"][0]
            self.assertEqual(fx["at"], 10000)
            self.assertTrue(fx["action_clock"])
            self.assertEqual(fx["offset_x"], 59)
            self.assertEqual(self.runtime["assets"]["effect_anims"][fx["key"]], builder.CHR_FX + effect)
            frames = manifest["effects"][fx["key"]]["frames"]
            self.assertIsNone(frames[0]["img"])
            self.assertNotIn("sprite", frames[0])
            self.assertIn("sprite", frames[1])

    def test_named_passives_and_morph_buffs_are_present(self):
        for skill_id in [
            "lightswordmastery",
            "equiplightsword",
            "shortswordmastery",
            "blademastery",
            "heavyswordmastery",
            "bluntmastery",
            "bloody_vigorous",
        ]:
            self.assertIn(skill_id, self.skills)
        self.assertEqual(self.skills["lightswordmastery"]["passive"][0]["weapon"], "beamsword")
        self.assertEqual(self.skills["equiplightsword"]["unlock_weapon"], "beamsword")
        self.assertEqual(self.runtime["effects"]["frenzy"]["form"], "dual_wield")
        self.assertIn("frenzy1", self.moves)
        self.assertIn("frenzy4", self.moves)

    def test_normalwave_level_columns_match_original_tooltip_order(self):
        record = self.pack["records"]["skill/swordman/normalwave.skl"]["decoded"]
        self.assertEqual(record["dungeon"]["level_info"][:7], [3,69,115,317,78,116,357])
        self.assertEqual(record["level_property"][-9:], [-1,2,1.0,-2,0,1.0,-1,1,1.0])
        hit = self.moves["normalwave"]["stages"][0]["hits"][0]
        self.assertEqual((hit.get("percent_col"),hit.get("fixed_col"),hit.get("size_col")), (2,0,1))

    def test_native_wave_binds_body_weapon_and_effect(self):
        stage=self.moves['normalwave']['stages'][0]
        self.assertEqual(self.moves['normalwave']['native_state'],'normalwave')
        self.assertEqual(stage['ani'],'wave')
        self.assertEqual(stage['hits'][0]['at'],10100)
        self.assertEqual(stage['fx'][0]['at'],10000)
        self.assertEqual(self.runtime['assets']['effect_anims'][stage['fx'][0]['key']],
                         'character/swordman/effect/animation/normalwaveslash.ani')
        appearance=json.loads((ROOT/'game_dnf/assets_local/weapon_appearance_v2/manifest.json').read_text(encoding='utf8'))
        for skin in appearance['appearances'].values():
            for layer in skin['layers']:
                ani=appearance['animations'][layer['clips']['wave']]
                self.assertTrue(ani['sync_body_frame'])
                self.assertEqual([f['img_frame'] for f in ani['frames']],list(range(42,51)))

    def test_job_derivatives_are_declared(self):
        triple = self.runtime["variants"]["triple"][0]
        self.assertEqual(triple["job"], "weaponmaster")
        self.assertEqual(len(triple["replace_stages"]), 5)
        self.assertEqual(self.runtime["variants"]["draw"][0]["job"], "weaponmaster")
        self.assertEqual(self.runtime["variants"]["rage_slash"][0]["job"], "berserker")
        self.assertEqual(self.runtime["variants"]["moonlight"][0]["job"], "soulbringer")

    def test_generated_assets_exist_in_the_source_pack(self):
        records = self.pack["records"]
        for path in self.runtime["assets"]["player_anims"].values():
            self.assertIn(path, records, path)
        for path in self.runtime["assets"]["effect_anims"].values():
            self.assertIn(path, records, path)
        for path in self.runtime["assets"]["objects"].values():
            self.assertIn(path, records, path)

    def test_runtime_assets_are_baked(self):
        manifest = json.loads(COMBAT.read_text(encoding="utf-8"))
        self.assertEqual(manifest["skill_runtime_sha256"], hashlib.sha256(RUNTIME.read_bytes()).hexdigest())
        base = json.loads((ROOT / "game_dnf/assets_local/manifest.json").read_text(encoding="utf-8"))
        player_clips = set(manifest["player_clips"]) | {
            key.removeprefix("player/") for key in base["clips"] if key.startswith("player/")
        }
        for key in self.runtime["assets"]["effect_anims"]:
            self.assertIn(key, manifest["effects"], key)
        for key in self.runtime["assets"]["player_anims"]:
            self.assertIn(key, player_clips, key)
        object_paths = {entry.get("object") for entry in manifest["objects"].values()}
        for path in self.runtime["assets"]["objects"].values():
            self.assertIn(path, object_paths, path)

    def test_passives_have_runtime_semantics(self):
        semantic_keys = {
            "passive",
            "mastery",
            "mastery_bonus",
            "unlock",
            "unlock_weapon",
            "dynamic",
            "aura",
            "on_hurt",
            "on_critical",
            "on_counter_evasion",
            "skill_level_bonus",
            "weapon_switch_buff",
            "durability_rate",
            "armor_mastery",
            "runtime_hook",
            "enhances",
            "profile_bonus",
        }
        for skill_id, skill in self.skills.items():
            if skill["active"]:
                continue
            self.assertTrue(semantic_keys.intersection(skill), skill_id)


if __name__ == "__main__":
    unittest.main()
