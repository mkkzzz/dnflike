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
    def test_source_paths_and_ids_are_unique(self):
        # Source-path identity is also used to migrate legacy save aliases.
        paths=[skill['path'] for skill in self.skills.values()]
        ids=[skill['source_id'] for skill in self.skills.values()]
        self.assertEqual(len(paths),len(set(paths)))
        self.assertEqual(len(ids),len(set(ids)))

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

    def test_throw_mastery_does_not_pollute_global_fixed_damage(self):
        skill = self.skills["throwmastery"]
        record = self.pack["records"][skill["source_path"]]["decoded"]
        self.assertEqual(record["level_info"], [1]+list(range(10,201,10)))
        self.assertEqual(record["consume_mp"], [1,1])
        self.assertEqual(skill["source_id"],177)
        self.assertFalse(skill.get("passive"))
        self.assertEqual(skill["runtime_status"],"pending_throw_item_pipeline")
        self.assertEqual(builder.generic_passive_spec("throwmastery"),
                         {"runtime_hook":"throw_item_mastery","runtime_status":"pending_throw_item_pipeline"})
        catalog=json.loads((ROOT/"game_dnf/data/skill_catalog.json").read_text(encoding="utf8"))
        source=next(s for s in catalog["skills"] if s["key"]=="throwmastery")
        self.assertIn("投掷道具",source["explain"])
        self.assertIn("不增加第2次伤害",source["explain"])
        from audit_dnf_skill_fidelity import audit
        subset=dict(self.runtime,skills={"throwmastery":skill})
        risk=audit(subset,{"moves":{}},self.pack["records"],catalog,set())["skills"][0]["risks"]
        self.assertIn("pending_runtime_consumer",risk)
        broken=dict(skill,passive=[{"stat":"physical_independent_attack","op":"add","level_row":0,"scale":1.0}])
        risk=audit(dict(subset,skills={"throwmastery":broken}),{"moves":{}},self.pack["records"],catalog,set())["skills"][0]["risks"]
        self.assertIn("throw_item_bonus_applied_to_general_character_stats",risk)

    def test_basic_mastery_does_not_boost_global_physical_attack(self):
        skill=self.skills["basicattackup"]
        self.assertEqual(skill["source_id"],174)
        self.assertFalse(skill.get("passive"))
        self.assertEqual(skill["runtime_status"],"pending_native_attack_record_pipeline")
        self.assertEqual(builder.generic_passive_spec("basicattackup"),
                         {"runtime_hook":"basic_attack_mastery","runtime_status":"pending_native_attack_record_pipeline"})
        from audit_dnf_skill_fidelity import audit
        catalog=json.loads((ROOT/"game_dnf/data/skill_catalog.json").read_text(encoding="utf8"))
        subset=dict(self.runtime,skills={"basicattackup":skill})
        risks=audit(subset,{"moves":{}},self.pack["records"],catalog,set())["skills"][0]["risks"]
        self.assertIn("pending_runtime_consumer",risks)
        broken=dict(skill,passive=[{"stat":"physical_attack","op":"percent","level_row":0,"scale":0.001}])
        risks=audit(dict(subset,skills={"basicattackup":broken}),{"moves":{}},self.pack["records"],catalog,set())["skills"][0]["risks"]
        self.assertIn("basic_attack_bonus_applied_to_general_character_stats",risks)

    def test_magical_memory_binds_only_original_duration_and_intelligence(self):
        source=self.pack["records"]["skill/swordman/magicalattackup.skl"]["decoded"]
        self.assertEqual(source["level_info"],[2]+[v for rank in range(1,21) for v in (20000,15*rank)])
        effect=self.runtime["effects"]["magical_memory"]
        self.assertEqual(effect["source_skill"],"magicalattackup")
        self.assertEqual(effect["duration_level_row"],0)
        self.assertEqual(effect["modifiers"],[{"stat":"intelligence","op":"add","level_row":1}])
        self.assertNotIn("duration_ms",effect)
        self.assertEqual(builder.BUFF_EFFECTS["magical_memory"],effect)
        self.assertEqual(self.moves["magicalattackup"]["effect_id"],"magical_memory")

    def test_normalwave_has_no_borrowed_upper_slash_damage_or_visual(self):
        move = self.moves["normalwave"]
        hits = [hit for stage in move["stages"] for hit in stage.get("hits", [])]
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0]["object"], "passiveobject/character/swordman/normalwave.obj")
        for stage in move["stages"]:
            for fx in stage.get("fx", []):
                self.assertNotIn("upperslash", self.runtime["assets"]["effect_anims"][fx["key"]])

    def test_native_cast_families_compare_live_binding_and_keep_object_gaps(self):
        from audit_dnf_skill_fidelity import native_cast_families

        combat = json.loads((ROOT / "game_dnf/data/combat.json").read_text(encoding="utf8"))
        records = self.pack["records"]
        families = native_cast_families(self.runtime, combat, records)
        by_id = {row["source_id"]: row for family in families.values() for row in family["members"]}
        for skill_id in (20, 21, 22, 25, 36, 41, 75):
            self.assertEqual(by_id[skill_id]["binding_differences"], [], skill_id)
        self.assertTrue(by_id[21]["fidelity_pending"])
        self.assertEqual(by_id[75]["expected"]["emissions"][0]["path"],
                         "passiveobject/character/swordman/epidemicrasacreater.obj")
        self.assertIn("attachment_abnormal_ticks", by_id[75]["fidelity_pending"])
        self.assertTrue(by_id[75]["tree_visible"])
        for skill_id in (96, 99, 100):
            self.assertFalse(by_id[skill_id]["tree_visible"])

        override = {"moves": dict(combat["moves"], normalwave={"stages": [{"ani": "summon2"}]})}
        ground_wave = native_cast_families(self.runtime, override, records)["swordman_wave"]["members"][0]
        self.assertEqual(ground_wave["binding_differences"], ["state", "ani", "emissions"])

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

    def test_native_wave_cast_sounds_are_original_and_base_only(self):
        manifest = json.loads(COMBAT.read_text(encoding="utf8"))
        rows = [
            ("normalwave", "HADOUKEN", "0a4228f8523534d6c9858cba5bc7229175f2a629e3f304313b656975fdacabe3"),
            ("icewave", "SM_ICEWAVE", "1c0ddbb4f646234d7b2b50495b141165b30ef6dfd55cb3c96b1c7885a6f652e4"),
            ("firewave", "SM_FIREWAVE", "2543e2fa411c7d8c92de0a8221176c39ef875aa403a5fbe5ef416b24fbf0fbba"),
        ]
        for skill, key, digest in rows:
            with self.subTest(skill=skill):
                self.assertEqual(self.moves[skill]["stages"][0]["voice"], key)
                self.assert_original_audio(manifest, key, digest)
        for skill in ("icewaveex", "firewaveex"):
            self.assertTrue(all("voice" not in stage for stage in self.moves[skill]["stages"]))
            self.assertIn("voice", self.moves[skill]["fidelity_pending"])

    def assert_original_audio(self, manifest, key, digest):
        bank, = manifest["audio"][key]
        self.assertEqual(bank["sha256"], digest)
        sample = ROOT / "game_dnf" / bank["file"].removeprefix("res://")
        self.assertEqual(hashlib.sha256(sample.read_bytes()).hexdigest(), digest)

    def test_ghost_field_sounds_are_original_and_bound_to_the_two_phases(self):
        manifest = json.loads(COMBAT.read_text(encoding="utf8"))
        rows = [
            ("khazan", "SM_GHOST_KAZHAN", "GHOST_KAJAN",
             "fabb3a7cc972fdcacdd1aecf4c61626923265fee8157ba321bdd35407eedbb20",
             "bf92a6f7752cc7a3b13c23b543225f7272e5bfb9ecc8446ced35de25636928d2"),
            ("bremen", "SM_GHOST_BREMEN", "GHOST_BREMEN",
             "b346924d13ae7eb1bee5723d797bd8bc13a6c085971f84947e881b5f84ec7f27",
             "13bf3c1737bf2e3202ec655b8727f8041fed2c6e4b93763630b623681503bbf5"),
            ("saya", "SM_GHOST_SAYA", "GHOST_SAYA",
             "36b208a425b1d39281859d0a2a73cac1abd0e691e163491f4a75fab76e507ad4",
             "aae0367dd1e330fa385031c6c39918dddb67b4290fa35a3c80ab9da56d01aad7"),
        ]
        for skill, cast_key, field_key, cast_digest, field_digest in rows:
            with self.subTest(skill=skill):
                stage = self.moves[skill]["stages"][0]
                self.assertNotIn("voice", stage)
                self.assertEqual(stage["sounds"], [{"at": 0, "key": cast_key}])
                self.assertEqual(stage["hits"][0]["native_controller"]["first_update_sound"], field_key)
                self.assert_original_audio(manifest, cast_key, cast_digest)
                self.assert_original_audio(manifest, field_key, field_digest)

    def test_ice_chain_bakes_each_original_variant_and_blank_tail(self):
        manifest = json.loads(COMBAT.read_text(encoding="utf8"))
        hit = self.moves["icewave"]["stages"][0]["hits"][0]
        controller = hit["native_controller"]
        self.assertEqual(controller["interval_ms"], self.pack["records"]["skill/swordman/icewave.skl"]["decoded"]["dungeon"]["static_data"][0])
        for ordinal, path in enumerate(controller["objects"]):
            bank = manifest["objects"][path]
            self.assertEqual(bank["source"], builder.OBJ_ROOT+f"animation/icewave{ordinal+1}.ani")
            self.assertEqual([f["img_frame"] for f in bank["frames"]], [ordinal*3,ordinal*3+1,ordinal*3+2,None])
            self.assertEqual([f["delay_ms"] for f in bank["frames"]], [80,50,50,100])
            self.assertNotIn("sprite",bank["frames"][-1])
            self.assertTrue((ROOT/"game_dnf"/bank["atlas"]["texture"].removeprefix("res://")).is_file())

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
        self.assertNotIn(b"\r\n", RUNTIME.read_bytes())
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

    def test_passives_declare_adapters_or_hooks_without_certifying_fidelity(self):
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
