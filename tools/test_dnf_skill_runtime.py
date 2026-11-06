"""Catalog/asset integrity and specific adapter regressions, not fidelity certification."""
import json
import unittest
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

    def test_normalwave_has_no_borrowed_upper_slash_damage_or_visual(self):
        move = self.moves["normalwave"]
        hits = [hit for stage in move["stages"] for hit in stage.get("hits", [])]
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0]["object"], "passiveobject/character/swordman/normalwave.obj")
        for stage in move["stages"]:
            for fx in stage.get("fx", []):
                self.assertNotIn("upperslash", self.runtime["assets"]["effect_anims"][fx["key"]])

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
