"""PTL regressions from the shipped ice definitions and adversarial field order."""
import json
import hashlib
from pathlib import Path
import unittest

from build_dnf_particles import parse
from compile_dnf_content import decode_fields
from dnf_particle_fields import decode_particle_fields

ROOT = Path(__file__).resolve().parents[1]
PREFIX = "passiveobject/character/swordman/particle/"


def field(tag, *values):
    return {"tag": tag, "values": list(values), "types": [], "offset": 2}


class ParticleFields(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.catalog = json.loads((ROOT/"game_dnf/assets_local/content/particles.json").read_text(encoding="utf8"))
        cls.pack = json.loads((ROOT/"game_dnf/assets_local/content/combat_content.json").read_text(encoding="utf8"))

    def test_original_ice_axes_are_independent_and_match_compiled_content(self):
        fixtures = [
            ("icewaveparticlestar",50,40,100,500,"c3cf3b07bd086517b508a95fa56d669362b6c7465e9636057612bb6a936c1c20"),
            ("icewaveparticle",1,30,500,500,"79f2237538306697422a6240aa57e562363d6594ced32f892cba95ce016699ff"),
            ("icewaveparticlesmoke",3,5,None,1000,"4d9fb45684ce5ca6a1f0e6391a3b40f9714c281d3d6d11135d3815152527dbcf"),
        ]
        for stem, x, z, gravity, life, sha in fixtures:
            path = PREFIX+stem+".ptl"
            entry = self.catalog["particles"][path]
            self.assertEqual(entry["sha256"], sha)
            decoded = entry["decoded"]
            self.assertEqual(decoded["axes"]["x"]["move_variable_1"], [x,x])
            self.assertEqual(decoded["axes"]["z"]["move_variable_1"], [z,z])
            self.assertNotIn("y",decoded["axes"])
            self.assertEqual(decoded.get("gravity"),gravity)
            self.assertEqual(decoded["life_time"],life)
            self.assertEqual(decoded,self.pack["records"][path]["decoded"])
            self.assertFalse(entry["unsupported"])

    def test_axis_selector_persists_and_global_fields_do_not_change_it(self):
        fields = [field("[move variable 1]",1,2),field("[z axis]"),field("[move variable 1]",30,40),
                  field("[gravity]",500),field("[changing term]",1000),field("[move variable 2]",7,8),
                  field("[y axis]"),field("[move type]","[sin]"),field("[x axis]"),field("[move variable 1]",9,10)]
        d, _, u = decode_particle_fields(fields,"a/b.ptl")
        self.assertEqual(d["axes"],{"x":{"move_variable_1":[9,10]},"z":{"move_variable_1":[30,40],"move_variable_2":[7,8]},"y":{"move_type":"[sin]"}})
        self.assertEqual((d["gravity"],d["changing_term"]),(500,1000))
        self.assertFalse(u)
        self.assertEqual(decode_fields("ptl",fields,"a/b.ptl")[0],d)

    def test_object_duplicates_and_uninterpreted_parameters_survive(self):
        d = self.catalog["particles"][PREFIX+"icewaveparticle.ptl"]["decoded"]
        entries = d["object_entries"]
        self.assertEqual(len(entries),7)
        self.assertEqual([e["parameter"] for e in entries],[-1]*7)
        self.assertEqual([e["path"].rsplit("/",1)[-1] for e in entries],
                         ["icewaveparticle1.ani","icewaveparticle2.ani","icewaveparticle3.ani"]+["icewaveparticle4.ani"]*4)

    def test_second_object_block_replaces_vector_as_native_reader_does(self):
        d,_,u = decode_particle_fields([field("[object]","first.ani",-1),field("[object]","../last.ani",7)],"a/b/c.ptl")
        self.assertEqual(d["object_entries"],[{"path":"a/last.ani","parameter":7}])
        self.assertFalse(u)

    def test_original_image_frames_use_image_manager_names_not_ptl_folder(self):
        path = "creature/bronzepig/effect/particle/pig_skill_stone.ptl"
        entry = self.catalog["particles"][path]
        self.assertEqual(entry["sha256"], "b042701ad1ce868bde6a8b5fcaa2e51105a223b30e8f30dfc2f95feb5504d03f")
        self.assertEqual(entry["decoded"]["object_entries"], [
            {"path": "creature/common/pig_part.img", "parameter": 2},
            {"path": "creature/common/pig_part.img", "parameter": 3},
        ])
        self.assertEqual(entry["animations"], [])
        # One original PTL mixes image indices with a relative ANI filename.
        entry = self.catalog["particles"]["monster/common/particle/monsterdiepieceveryyoung.ptl"]
        self.assertEqual(entry["sha256"], "e45acd817ecbedeedcff53f35a56fcee2449da5c28294a90290f105b95d8471c")
        self.assertEqual(entry["decoded"]["object_entries"], [
            {"path": "monster/common/monsterdiepieceveryyoung.img", "parameter": 0},
            {"path": "monster/common/monsterdiepieceveryyoung.img", "parameter": 1},
            {"path": "monster/common/animation/monsterdiepieceveryyoung.ani", "parameter": -1},
        ])

    def test_empty_object_names_survive_for_animation_and_passive_objects(self):
        count = 0
        for path, entry in self.catalog["particles"].items():
            blocks = [n for n in entry["raw"] if n["tag"] == "[object]"]
            if not blocks:
                continue
            values = blocks[-1]["values"]
            for i in range(0, len(values)-1, 2):
                if values[i] == "":
                    count += 1
                    self.assertEqual(entry["decoded"]["object_entries"][i//2],
                                     {"path": "", "parameter": values[i+1]}, path)
        self.assertEqual(count, 156)

    def test_object_type_after_list_and_parameter_choose_reference_namespace(self):
        fields = [field("[object]", "../anim.ani", -1, "Sprite\\Parts.img", 7, "", -1),
                  field("[object type]", "[animation]")]
        d, _, u = decode_particle_fields(fields, "root/particle/mixed.ptl")
        self.assertEqual(d["object_entries"], [
            {"path": "root/anim.ani", "parameter": -1},
            {"path": "sprite/parts.img", "parameter": 7},
            {"path": "", "parameter": -1},
        ])
        self.assertFalse(u)
        # Filename suffix alone cannot turn an indexed image into an ANI dependency.
        indexed = parse("root/test.ptl", {"fields": [field("[object]", "fake.ani", 3),
                                                   field("[object type]", "[animation]")]})
        self.assertEqual(indexed["animations"], [])

    def test_unknown_language_and_malformed_values_remain_in_raw(self):
        fields = [field("[unknown internal tag]","내부 값"),field("[move variable 1]",50),field("[object]","ok.ani",-1,"unpaired.ani")]
        entry = parse("a/b.ptl",{"fields":fields,"sha256":"test"})
        self.assertEqual(entry["raw"],fields)
        self.assertEqual(len(entry["unsupported"]),3)
        self.assertNotIn("x",entry["decoded"]["axes"])
        self.assertEqual(entry["animations"],["a/ok.ani"])

    def test_compiled_throwers_read_x_axis_even_with_other_axes(self):
        found = 0
        for entry in self.pack["records"].values():
            if entry["kind"]!="ptl":continue
            fields = entry["raw"]
            expected, _, _ = decode_particle_fields(fields,entry["id"])
            self.assertEqual(expected,entry["decoded"])
            if "move_variable_1" in expected["axes"].get("x",{}):found += 1
        self.assertGreater(found,20)

    def test_generated_provenance_covers_shared_decoder_on_both_platforms(self):
        def digest(names):
            return hashlib.sha256(b"".join((ROOT/"tools"/name).read_bytes().replace(b"\r\n",b"\n") for name in names)).hexdigest()
        self.assertEqual(self.pack["compiler_sha256"],digest(["compile_dnf_content.py","dnf_pvf.py","dnf_particle_fields.py"]))
        self.assertEqual(self.catalog["extractor_sha256"],digest(["build_dnf_particles.py","dnf_particle_fields.py","dnf_pvf.py"]))

    def test_catalog_records_do_not_claim_unknown_fields_are_decoded(self):
        self.assertEqual(self.catalog["schema"],"dnf_particles/2")
        self.assertEqual(self.catalog["count"],len(self.catalog["particles"]))
        self.assertEqual(self.catalog["failed"],len(self.catalog["failures"]))
        for path,entry in self.catalog["particles"].items():
            self.assertEqual(len(entry["sha256"]),64,path)
            d,e,u = decode_particle_fields(entry["raw"],path)
            self.assertEqual((d,e,u),(entry["decoded"],entry["evidence"],entry["unsupported"]),path)


if __name__ == "__main__":
    unittest.main()
