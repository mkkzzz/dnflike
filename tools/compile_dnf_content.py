"""Compile original combat content into a reproducible content pack (doc 29, F2).

Scope v1: the swordman character, every attack info and skill reachable from it, the
animations those reference, and the goblin-family monsters with their actions/attacks.
Output (git-ignored): game_dnf/assets_local/content/combat_content.json plus a field
coverage report covering the WHOLE archive for ATK/SKL/CHR/MOB, so the backlog of
unsupported fields is explicit.

Records follow docs/design/29_新版工程框架_接口契约.md section 5:
  id, kind, raw (ordered field tree), decoded (named fields), evidence, unsupported, source.
Decoded fields carry E-PARSE (structure read) or E-INFER (meaning/unit inferred). Runtime
semantics of a field become E-RUN only after in-game verification; nothing here claims that.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
from pathlib import Path, PurePosixPath
import sys

from dnf_pvf import Library, canonical, find, key_of, open_library, resolve
from dnf_asset_store import ROOT
from dnf_particle_fields import decode_particle_fields

OUT = ROOT / 'game_dnf/assets_local/content'
SCHEMA = 'dnf_combat_content/1'
COMPILER_VERSION = 5
HANDLED_FILE = ROOT / 'game_dnf/combat/fields/handled.json'

# These bindings come from native state handlers, outside the MOB field tree.
# Keep each source payload pinned before admitting an engine-derived binding.
NATIVE_ATTACK_EMISSIONS = {
    'monster/vehicle/catapult.mob': {
        'mob_id': 270,
        'slots': [
            {'slot': 0, 'frame': 11, 'object_int_index': 0, 'object_id': 30034,
             'ptl_path': 'monster/vehicle/particle/cannonballangle.ptl', 'offset': [70, 0, 50],
             'sound': 'DRGCANNON_SHOOT'},
            {'slot': 1, 'frame': 11, 'object_int_index': 0, 'object_id': 30034,
             'ptl_path': 'monster/vehicle/particle/cannonballdirect.ptl', 'offset': [70, 0, 50],
             'sound': 'DRGCANNON_SHOOT'},
        ],
        'sha256': {
            'monster/vehicle/catapult.mob': 'fa9ca03ece94f84a37ffe3d937f63877a3ffb785a6f1a85b02e6b34e37db11ff',
            'monster/vehicle/catapultani/fire.ani': 'c9f71d55421bae61c900012a2b89fb22b6f4d475f3e03ad7dd13d918d5e4990d',
            'monster/vehicle/attackinfo/ctfire.atk': '754ed0ad14b0704d7b5926594e39faac697f6cbc6ff4dd96a65b87b590b9236e',
            'monster/vehicle/particle/cannonballangle.ptl': 'b864ddbb1b955cebebe0c758bd11877d0471fa51b10cc557bfa9aa3b874d33ea',
            'monster/vehicle/particle/cannonballdirect.ptl': '13b4bdf73a5b01db151839a9dbb9f1a87ccc911915fa810859c3c2dfeb5f3316',
            'passiveobject/monster/vehicle/cannonball.obj': '844fc4cbdf1c8bb380f01930d822379ae0be1a89da273b532766e83e9a015c70',
            'passiveobject/monster/vehicle/ani/cannonball.ani': '3a1c4c5b786e50c227b2cd39fe6a3746f50b5c8ec194b6b593680b3dbab23056',
            'passiveobject/monster/vehicle/attackinfo/cannonball.atk': '2dfec2eec5602afc3c44f0cd85095ed8630f04c7ff83c049bba6ca166faf3b2b',
        },
        'source': {
            'engine_sha256': '187ad34ab6bfff040d9b12bb145bdda0bba29f82aaa41183280b0ae42e914b84',
            'frame_latch': '0xDBA080',
            'object_id_binding': '0xDBA557',
            'slot_dispatch': '0x26A0252',
            'relative_spawn': '0x86DDB0',
            'motion_attachment': '0xE5ACA9..0xE5ACBA',
            'release_sound': '0xDBA10C',
        },
        'selection_source': {
            'initial_ms': 3000,
            'down_gate_percent': 0,
            'hostile_team': '0x895031',
            'normal_ai_call': '0x8782ED',
            'attempt_deadline': '0x8837DE..0x88384F',
            'attack_rows': '0x12A528E..0x12A547B',
            'target_area': '0x877CE0',
            'target_affiliation': '0x878427..0x87849D',
            'slot_probabilities': '0x8784D0..0x878593',
            'down_gate_default': '0x87EE69..0x87EE93',
            'no_target_probability': '0x878710..0x87875A',
            'uniform_candidate': '0x8838FB..0x88394E',
        },
    },
}

NATIVE_ATTACK_CONTACTS = {
    'monster/zealot/bosspope.mob': {
        'mob_id': 266,
        'slot': 0,
        'object_id': 30073,
        'object_bank': 'native_pope_thunderbolt',
        'target_class': 0x11,
        'chance_percent': 50,
        'sha256': {
            'monster/zealot/bosspope.mob': '826cf924373c6d0a3957b038e813b1e4c8f45c33617feffb1b4617eb414318a6',
            'monster/zealot/popeani/attack.ani': '645c08d1f4e5eb7f020b8f648bb1843d069ce024a12ad02ad1233b1ccbc4f9e0',
            'monster/zealot/attackinfo/poattack.atk': '3438c21857b666e5954a09f356dbfee55aec415418b9803e102d477b0a7d8d8a',
            'passiveobject/monster/zealot/popethunderbolt.obj': '9758107fdf088324b2eb445eb1102576ad97381a4281901190b3563e7ab1c735',
            'passiveobject/common/animation/thunderbolt.ani': 'c40004818e6b97ed2aceb7ff24d2ffc1b20632d83a225c803c5b7257d79b3570',
            'passiveobject/monster/zealot/attackinfo/popethunderbolt.atk': '2a1efe652ed70b3abcbd2c091a43ff4e0c11d4c061a6803c44176fbcd3dd6e95',
        },
        'source': {
            'engine_sha256': '187ad34ab6bfff040d9b12bb145bdda0bba29f82aaa41183280b0ae42e914b84',
            'contact': '0xDBBB10..0xDBBBE0',
            'spawn': '0xDBBB83..0xDBBBD2 → 0x86DF60',
        },
    },
}

NATIVE_ZEALOT_MONSTERS = {
    'native_raxy': 'monster/zealot/raxy-a.mob',
    'native_starfish': 'monster/starfish/starfish.mob',
    'native_starfish_rukuku': 'monster/starfish/starfishrukuku.mob',
}
NATIVE_OUTERWALL_MOBS = {
    265: ('native_bossfather', 'monster/zealot/bossfather.mob',
          'e1c3ca23b7ad4ba9c6067f0c70b8f958cc62aadebdc2408b037af0241252727c'),
    266: ('native_bosspope', 'monster/zealot/bosspope.mob',
          NATIVE_ATTACK_CONTACTS['monster/zealot/bosspope.mob']['sha256']['monster/zealot/bosspope.mob']),
    270: ('native_catapult', 'monster/vehicle/catapult.mob',
          NATIVE_ATTACK_EMISSIONS['monster/vehicle/catapult.mob']['sha256']['monster/vehicle/catapult.mob']),
}
NATIVE_OUTERWALL_BANKS = {key: path for key, path, _sha in NATIVE_OUTERWALL_MOBS.values()}
OUTERWALL_BREAKABLE_ROOT = 'passiveobject/mapobject/breakableobject/'
NATIVE_OUTERWALL_BREAKABLES = {
    300: ('collectionboxforlotus', 'collectionboxforlotus', 'collectionboxdestroy',
          '4966224594c08f2d04e23ab1da26b5e00756565767a096cf7b07eae54c720729',
          '92cab2a2a6b9d89a227b2b674e2cdf20421c840bc40d951413b0b78696816cf9',
          '581c42fbb7e606b681d7ab562ac83e9238e3f27c37e4bd19ad05f84851606a49'),
    770: ('outerwalllongchair', 'longchair', 'longchairdestroy',
          '169380edd84a84dfc77d33678a5e6ed2d6b4dd8e3b08277cd39775268ebce27d',
          'a354a764957001a52eb0adb43709b8a559d022c6650ea2e7075a7651da561e9e',
          'c659872bcf512a5e77ed9f77f8d80b0158dee98db873edec9fe593cdc1c604b8'),
    771: ('outerwalllongpot', 'longpot', 'longpotdestroy',
          '74b3c83364a8848f552798a663ad1e57cf8640f56ab146c7dcaf4e6306962c89',
          'ebf839e8df70e9b1e4da0da1b76b3a339731c886861d59e75f7997e1595bfade',
          '0856c4e55f330aa2d057b6831050777608db86cbec0f300c9ee1db0d951309fb'),
}
NATIVE_JAR_TRAP_WARNING = 'common/commoneffect/animation/trapexclamation.ani'
NATIVE_JAR_TRAP_RATE = 'etc/difficultpenalty.etc'
NATIVE_JAR_TRAP_COMMON = 'passiveobject/common/'
NATIVE_JAR_TRAP_FAIRY = OUTERWALL_BREAKABLE_ROOT + 'fairy/'
NATIVE_JAR_GAS_DUNGEON = 'dungeon/act3/outerwall.dgn'
NATIVE_JAR_GAS_STATUS_TABLE = 'etc/activestatustable_ex.etc'
NATIVE_JAR_GAS_SHA = {
    NATIVE_JAR_GAS_DUNGEON: '4bc1517d37fdefdd4288ff0766a0bdc52d4c03248ca5e8d395e02354f05b08b8',
    NATIVE_JAR_GAS_STATUS_TABLE: '8c94c682a3e2e39835816a1af27b8ffa66d50d161e15aee50d07d0604776a599',
}
NATIVE_JAR_TRAP_OBJECTS = {
    NATIVE_JAR_TRAP_COMMON + 'fireexplosion.obj': ((40002,), 'fire'),
    NATIVE_JAR_TRAP_COMMON + 'cloudkill.obj': ((48003,), 'poison'),
    NATIVE_JAR_TRAP_FAIRY + 'hpmpfairy.obj': ((2200, 2210), 'hpmp_fairy'),
    NATIVE_JAR_TRAP_FAIRY + 'invinsiblefairy.obj': ((2410,), 'invincibility_fairy'),
}
NATIVE_JAR_TRAP_SHA = {
    NATIVE_JAR_TRAP_WARNING: '85bdb1155196f53aca0a2d993c5ed09db4010a73d5031dc214797db617f3deb8',
    NATIVE_JAR_TRAP_RATE: '4378483366ccab2691749e0f48e41c0398776507ceb917e6859f5f21e0701d9a',
    **{NATIVE_JAR_TRAP_COMMON + path: digest for path, digest in {
        'animation/cloudkill.ani': '3e950b31c0bf2ef09aac1becdcc1c9cdc6998caca7631212ce7c3da5cb4edb22',
        'animation/fireexplosion.ani': 'f51bef6a57be8132a8698447bd72c6c80983549e1a6c2db3d3abda52e96f74c4',
        'animation/fireexplosionparticle1.ani': '66b4126dbe82ecf1875c87423d92ee5a8066dc31ae5da0ccc43b2ab1ee2f3866',
        'animation/fireexplosionparticle2.ani': 'f116dbc72cb70453dc87199556ae68704599954f1014368bbc113afcdd92682e',
        'animation/fireexplosionparticle3.ani': '870b567b24d7e01422f4ae5e0cf1a1b4981a730907da2411c80fee34e9ddb9f1',
        'animation/fireexplosionparticle4.ani': '4cdd032d48b183698b6e98cebdd6a2e77aebd9115bb9082494ab3a761e892cc3',
        'animation/poisonsmoke.ani': '7f630d8365a791c2f018b643f6c1d69e9f376496adc34b338956c8e27e1f8d0b',
        'animation/poisonsmoke2.ani': '93f68f07c5f54442de7293a2748f45f6c675819aac4f16cf4045c92c333b9ed7',
        'attackinfo/cloudkill.atk': '446f6a3ea884d3add7971c286b9b71a1c71872856d2a571efb39b78545186b04',
        'attackinfo/fireexplosion.atk': '84af81374a841e83bce1279352e60c85134841444546ff11aadecfaeecd306cb',
        'cloudkill.obj': '9538676ea3c18f8babb4bca34cda5a46dbd2ee576fa7efbf426cd8c54e517d40',
        'fireexplosion.obj': 'ca64017a803f74bde1dfc4d7fad854d784a19fa75df2422b8d57adc58c74949e',
        'particle/fireexplosionparticle1.ptl': '133de360602dec17fc9b200666ffe1895f96a2a31318c09199004af5ad5da79d',
        'particle/fireexplosionparticle2.ptl': '13f31f30e1357152ef6807b0ea5e8aef1533be73686f155a9ee735ae9cd51f98',
        'particle/fireexplosionparticle3.ptl': '39ab1fb24c2b5fc267a4ea92b0fe1129125a4dd555d32afecb0c8fab05b3a28e',
        'particle/fireexplosionparticle4.ptl': 'fe486a39ebf731210bcd74a17c42b60b679d2e646018b230d674778c4b2d977c',
        'particle/poisongas.ptl': '3f94d8cfb6e68f0d32c52ebdc45ee875bb07c8707f956c5b9d3174db5db3ce4d',
    }.items()},
    **{NATIVE_JAR_TRAP_FAIRY + path: digest for path, digest in {
        'animation/heart.ani': '9d8bdbd1a421cc1c3a8e42bfa13cf2e2019db37f3fd3a19b8bf48435bb7f028d',
        'animation/heartdestroy.ani': '522acaa599c8145e4aa825e387ec809540ce67ea29386d733ca51c40ee18f52b',
        'animation/hpmpfairy.ani': '2b23c81314baa246e1313e718ccd6d39e7d6195d13905f4811c34ac673769155',
        'animation/hpmpfairydestroy.ani': '53917dab0029eabd3415f494bfdc3ad113b4625c9a2e63a6643b41ca85597925',
        'animation/hpmpfairyef.ani': '3acd353c889efb6f1defd43819aaa19536b773540b943d285a774af2178fc483',
        'animation/invinsiblefairy.ani': '87b64bebb17ceb596a8ea6c9f9428d63f41de4c994ad54e1b200d8aa3d95e8a5',
        'animation/invinsiblefairydestroy.ani': '18c902271f1ae68adcb173db4462133eb860622b51b43a83544ac6159310f9ad',
        'animation/invinsiblefairyef.ani': '38761edefd9450ae4bded24df0549a6a1e6f77e9dd8e523af49cc9fe7c93e00b',
        'attackinfo/fairy.atk': '9a2f3fb9c281bf046b623051cea2b5e07275a817ea2c6da031f161bbd0c4fc9c',
        'hpmpfairy.obj': '182e22d890b40edea5883409a4a29366877bb5d8aa3fa329da07dfa3384a0da8',
        'invinsiblefairy.obj': '799ddff60c30db44854be21c0adaac7395ceb7ee1b1a11b9d0d3aae8d54352b5',
    }.items()},
}
NATIVE_ZEALOT_SOURCE_SHA = '187ad34ab6bfff040d9b12bb145bdda0bba29f82aaa41183280b0ae42e914b84'
NATIVE_POISON_PARTICLE = 'common/activestatus/particle/poisonparticle.ptl'
NATIVE_POISON_VISUAL_SHA = {
    NATIVE_POISON_PARTICLE: '27bf1336ab1d9d99fc03edbc9550d660ef7717c552c68afd711f750b9382cd0e',
    'common/activestatus/animation/poisonparticle1.ani': '672214f7a7f39d9d489c27b4928f5f394b8c52987a3e49ec5eb8c078e00fffe5',
    'common/activestatus/animation/poisonparticle2.ani': '6f7a6de95ad42aa0540bc0c9a61b3db7bcedb88345ebe0bea814b4f5817661ec',
}
NATIVE_RAXY_SOURCE = {
    'monster/zealot/raxy-a.mob': '5a6e4599e577eff2668d7cbe14faefe7a577dff0f89b45fb9d1f3f5beb39e7b7',
    'monster/zealot/raxy-aani/suicide.ani': 'a8e439f2004b1228e927179931e6d2d332d87c8c73b7a0ec49259bf0731e16b0',
}
NATIVE_STARFISH_JUMPS = {
    'monster/starfish/starfish.mob': {
        'mob_id': 250,
        'sha256': {
            'monster/starfish/starfish.mob': 'b74c5dd76b58b1d653df13974fde343f91b667cda8947fc5899d6588d461490b',
            'monster/starfish/tentacleanimation/jumpattackstart.ani': 'b93424ba86001c7ebebfdd89ad16d6e7a0b9c9f2c02941c58f7e85f3a1e626fe',
            'monster/starfish/tentacleanimation/jumpattackrolling.ani': 'd381e6e7b58b1178c5614254b1c4469e3b4f6a22f9c5ff4d830dd9dd2aa1519c',
            'monster/starfish/tentacleanimation/jumpattackend.ani': '5ccb59b2d40f721fd17ea094b8f341912cfa78d22e0589d0cce98a2e3bad6716',
        },
    },
    'monster/starfish/starfishrukuku.mob': {
        'mob_id': 252,
        'sha256': {
            'monster/starfish/starfishrukuku.mob': 'f300a2345a0a3ef9ccd101b90236bf91f63073ac3e69477ef3123cbc975312c2',
            'monster/starfish/rukanimation/jumpattackstart.ani': '93791bd7de8df17ac88fae890221f2495e1db686c19399e5235dfa624eec4eec',
            'monster/starfish/rukanimation/jumpattackrolling.ani': 'acc7262c9a04bc338aa261d83f60b8f4fdd0e59cc52493e7dc151353b858e92d',
            'monster/starfish/rukanimation/jumpattackend.ani': '2d679c0fbc58d960911a4b591fc8ffe0809a051d60621932ee393956a4a4b03d',
        },
    },
}
NATIVE_STARFISH_ATTACKS = {
    'monster/starfish/attackinfo/jumpattack.atk': '4a38742299a6e80ce01892c824c67560de893952f26f73e6590718b07da6d373',
    'monster/starfish/attackinfo/rolling.atk': 'd486fda9ae49937caaeba5d39da9676a4ab30e345377b6cf0d624d5ea4845735',
}
NATIVE_STARFISH_BITE = {
    'monster/starfish/tentacleanimation/trybite.ani': '5586aa301c97dcb237c52942de4190036bdf31443ec33cb23513bdc77443a032',
    'monster/starfish/tentacleanimation/bite.ani': '7ef2d8fb6e6981ce8b2000909125f4f7fc3cdffb7467d5ace50e78674e427efd',
    'monster/starfish/tentacleanimation/releasebite.ani': '2c5c961fd1138175b08a3f8c4249206499c3043bd7d59d07c1b5298414dd607a',
    'monster/starfish/attackinfo/trybite.atk': 'a6d0af61f777ccec6812e0a4f7a154e342b8396a311bf227d3b44e64bfe08f34',
    'monster/starfish/attackinfo/bite.atk': '45e25ac0f488b6594ccdb3573c48c311e731d906a97b2d8d60311e3a7964a7d4',
}

# Decoders: canonical tag -> (decoded key, shape, evidence, note). Shapes:
#   int|float|str = first value; list = all values; enum = canonical enum tag(s); flag = presence.
ATK_FIELDS = {
    '[damage bonus]': ('damage_bonus', 'atk_integer', 'E-PARSE', 'Original 1218A80 integer reader -> attack record +24; final damage formula unresolved'),
    '[absolute damage]': ('absolute_damage', 'number', 'E-PARSE', ''),
    '[attack type]': ('attack_type', 'enum', 'E-PARSE', 'physic / magic / ignore defense'),
    '[weapon damage apply]': ('weapon_damage_apply', 'int', 'E-PARSE', ''),
    '[attack enemy]': ('attack_enemy', 'int', 'E-PARSE', ''),
    '[attack friend]': ('attack_friend', 'int', 'E-PARSE', ''),
    '[attack myself]': ('attack_myself', 'int', 'E-PARSE', ''),
    '[elemental property]': ('element', 'enum', 'E-PARSE', ''),
    '[damage reaction]': ('damage_reaction', 'enum', 'E-PARSE', 'damage (stagger) / down / none'),
    '[push aside]': ('push_aside', 'int', 'E-PARSE', 'Horizontal knockback; unit unknown'),
    '[lift up]': ('lift_up', 'int', 'E-PARSE', 'Vertical launch; unit unknown'),
    '[attack direction]': ('attack_direction', 'enum', 'E-PARSE', 'hit horizon / hit down / hit lift up'),
    '[hit info]': ('hit_info', 'enum', 'E-PARSE', '[kind][blood] then effect scale values'),
    '[hit wav]': ('hit_wav', 'str', 'E-PARSE', 'Sound key in the audio table'),
    '[knuck back]': ('knock_back', 'list', 'E-PARSE', ''),
    '[bounce]': ('bounce', 'int', 'E-PARSE', ''),
    '[stuck]': ('stuck', 'number', 'E-PARSE', 'Hit-stop related; unit unknown'),
    '[active status]': ('active_status', 'enum', 'E-PARSE', 'Status effect with its values'),
    '[hit direction]': ('hit_direction', 'enum', 'E-PARSE', ''),
    '[ignore super armor]': ('ignore_super_armor', 'int', 'E-PARSE', ''),
    '[ignore weight]': ('ignore_weight', 'int', 'E-PARSE', ''),
    '[ignore defense]': ('ignore_defense', 'list', 'E-PARSE', ''),
    '[critical hit]': ('critical_hit', 'int', 'E-PARSE', ''),
    '[max target hit number]': ('max_targets', 'int', 'E-PARSE', ''),
    '[is hit number increasing]': ('hit_number_increasing', 'int', 'E-PARSE', ''),
    '[monster damage rate]': ('monster_damage_rate', 'float', 'E-PARSE', ''),
    '[human damage rate]': ('human_damage_rate', 'float', 'E-PARSE', ''),
    '[pvp]': ('pvp', 'section', 'E-PARSE', 'PvP overrides; out of PvE scope'),
    '[damage]': ('damage', 'number', 'E-PARSE', 'Numeric form (enum form is consumed by [damage reaction])'),
    '[MP drain]': ('mp_drain', 'int', 'E-PARSE', ''),
    '[HP drain]': ('hp_drain', 'int', 'E-PARSE', ''),
}
SKL_FIELDS = {
    '[name]': ('name_ref', 'list', 'E-PARSE', 'Localized string link (type 9/10), unresolved'),
    '[type]': ('type', 'list', 'E-PARSE', ''),
    '[skill class]': ('skill_class', 'int', 'E-PARSE', ''),
    '[maximum level]': ('max_level', 'int', 'E-PARSE', ''),
    '[required level]': ('required_level', 'int', 'E-PARSE', ''),
    '[required level range]': ('required_level_range', 'int', 'E-PARSE', ''),
    '[purchase cost]': ('purchase_cost', 'list', 'E-PARSE', ''),
    '[growtype maximum level]': ('growtype_max_level', 'list', 'E-PARSE', ''),
    '[skill fitness growtype]': ('fitness_growtype', 'list', 'E-PARSE', ''),
    '[icon]': ('icon', 'list', 'E-PARSE', 'IMG path + frame, normal then disabled'),
    '[command]': ('command', 'list', 'E-PARSE', 'Out of scope: D006 shortcut only'),
    '[weapon effect type]': ('weapon_effect_type', 'list', 'E-PARSE', ''),
    '[auto cooltime apply]': ('auto_cooltime_apply', 'int', 'E-PARSE', ''),
    '[durability decrease rate]': ('durability_decrease_rate', 'int', 'E-PARSE', ''),
    '[dungeon]': ('dungeon', 'context', 'E-PARSE', 'PvE context: consume MP, cool time, static data, level info'),
    '[pvp]': ('pvp', 'section', 'E-PARSE', 'PvP context; out of scope'),
    '[death tower]': ('death_tower', 'section', 'E-PARSE', 'Mode context; out of scope'),
    '[warroom]': ('warroom', 'section', 'E-PARSE', 'Mode context; out of scope'),
    '[level property]': ('level_property', 'list', 'E-PARSE', 'Tooltip formula rows; unresolved'),
    '[feature skill index]': ('feature_skill_index', 'int', 'E-PARSE', ''),
    '[consume MP]': ('consume_mp', 'list', 'E-PARSE', 'Mode-less form; same layout as [dungeon] child'),
    '[cool time]': ('cool_time', 'list', 'E-PARSE', 'Milliseconds (E-INFER); mode-less form'),
    '[static data]': ('static_data', 'list', 'E-PARSE', 'Skill-specific constants; meaning per skill'),
    '[level info]': ('level_info', 'list', 'E-PARSE', 'First value = columns per level, then rows'),
    '[casting time]': ('casting_time', 'list', 'E-PARSE', ''),
    '[consume item]': ('consume_item', 'list', 'E-PARSE', ''),
    '[pre required skill]': ('pre_required_skill', 'list', 'E-PARSE', 'Skill index, level pairs'),
    '[shake screen]': ('shake_screen', 'list', 'E-PARSE', ''),
    '[skill command advantage]': ('command_advantage', 'list', 'E-PARSE', 'Out of scope: D006 shortcut only'),
    '[name2]': ('name2_ref', 'list', 'E-PARSE', 'Localized string link, unresolved'),
    '[explain]': ('explain_ref', 'list', 'E-PARSE', 'Localized string link, unresolved'),
    '[basic explain]': ('basic_explain_ref', 'list', 'E-PARSE', 'Localized string link, unresolved'),
    '[start cool time]': ('start_cool_time', 'list', 'E-PARSE', ''),
    '[executable states]': ('executable_states', 'list', 'E-PARSE', 'States from which the skill may start'),
}
CHR_FIELDS = {
    '[job]': ('job', 'list', 'E-PARSE', ''),
    '[width]': ('width', 'list', 'E-PARSE', 'Body width/depth; unit unknown'),
    '[initial value]': ('initial', 'stats', 'E-PARSE', 'Level-1 base stats until the next group tag'),
    '[skill]': ('base_skills', 'pairs', 'E-PARSE', 'Skill index, level'),
    '[attack motion]': ('attack_motions', 'paths', 'E-PARSE', ''),
    '[attack info]': ('attack_infos', 'paths', 'E-PARSE', 'Aligned with attack motion'),
    '[jumpattack info]': ('jumpattack_info', 'paths', 'E-PARSE', ''),
    '[dashattack info]': ('dashattack_info', 'paths', 'E-PARSE', ''),
    '[etc attack info]': ('etc_attack_infos', 'paths', 'E-PARSE', ''),
    '[etc motion]': ('etc_motions', 'paths', 'E-PARSE', ''),
    '[weapon wav]': ('weapon_wav', 'repeat_list', 'E-PARSE', 'Per weapon subtype: swing A, swing B, hit A, hit B'),
    '[weapon hit info]': ('weapon_hit_info', 'list', 'E-PARSE', 'Per weapon subtype: kind, blood, then 4 numbers'),
    '[weapon skill info]': ('weapon_skill_info', 'list', 'E-PARSE', ''),
    '[upgrade weapon attack power rate]': ('upgrade_weapon_attack_rate', 'list', 'E-PARSE', ''),
    '[growtype name]': ('growtype_name_refs', 'list', 'E-PARSE', 'Localized string links'),
    '[awakening name]': ('awakening_name_refs', 'list', 'E-PARSE', 'Localized string links'),
    '[ghost motion]': ('ghost_motions', 'paths', 'E-PARSE', ''),
    '[body image path]': ('body_image', 'list', 'E-PARSE', ''),
}
for motion in ['waiting', 'move', 'sit', 'damage motion 1', 'damage motion 2', 'down', 'overturn', 'jump',
               'jumpattack', 'rest', 'dash', 'dashattack', 'getitem', 'buff', 'back']:
    tag = f'[{motion} motion]' if 'motion' not in motion else f'[{motion}]'
    CHR_FIELDS[tag] = (key_of(tag), 'paths', 'E-PARSE', '')
STAT_TAGS = ['[HP MAX]', '[MP MAX]', '[physical attack]', '[physical defense]', '[magical attack]', '[magical defense]',
             '[dark resistance]', '[light resistance]', '[fire resistance]', '[water resistance]', '[inventory limit]',
             '[MP regen speed]', '[move speed]', '[attack speed]', '[cast speed]', '[hit recovery]', '[jump power]',
             '[weight]', '[jump speed]', '[HP regen speed]']
GROUP_EXTRAS = ['[module damage rate]', '[skill]', '[awakening skill]']
MOB_FIELDS = {
    '[width]': ('width', 'list', 'E-PARSE', ''),
    '[ability category]': ('ability_category', 'list', 'E-PARSE', 'Stat, operator, percent triples'),
    '[category]': ('category', 'list', 'E-PARSE', ''),
    '[level]': ('level', 'list', 'E-PARSE', 'min, max'),
    '[move speed]': ('move_speed', 'list', 'E-PARSE', 'min, max'),
    '[attack speed]': ('attack_speed', 'list', 'E-PARSE', ''),
    '[cast speed]': ('cast_speed', 'list', 'E-PARSE', ''),
    '[hit recovery]': ('hit_recovery', 'list', 'E-PARSE', ''),
    '[weight]': ('weight', 'list', 'E-PARSE', ''),
    '[sight]': ('sight', 'int', 'E-PARSE', ''),
    '[warlike]': ('warlike', 'int', 'E-PARSE', ''),
    '[attack delay]': ('attack_delay', 'int', 'E-PARSE', 'Milliseconds (E-INFER)'),
    '[targeting nearest]': ('targeting_nearest', 'int', 'E-PARSE', ''),
    '[attack kind]': ('attack_kind', 'list', 'E-PARSE', ''),
    '[item]': ('drop_items', 'list', 'E-PARSE', 'Item id, weight pairs; flow side'),
    '[die effect]': ('die_effect', 'list', 'E-PARSE', ''),
    '[face image]': ('face_image', 'list', 'E-PARSE', ''),
    '[attack motion]': ('attack_motions', 'paths', 'E-PARSE', ''),
    '[attack info]': ('attack_infos', 'paths', 'E-PARSE', ''),
    '[name]': ('name_ref', 'list', 'E-PARSE', 'Localized string link, unresolved'),
    '[etc motion]': ('etc_motions', 'paths', 'E-PARSE', ''),
    '[floating height]': ('floating_height', 'list', 'E-PARSE', ''),
    '[hp regen rate]': ('hp_regen_rate', 'list', 'E-PARSE', ''),
    '[stuckbonus on damage]': ('stuck_bonus_on_damage', 'list', 'E-PARSE', 'Hit-stop related; meaning unknown'),
    '[int data]': ('int_data', 'list', 'E-PARSE', 'Monster-specific constants'),
    '[throw attack]': ('throw_attack', 'tagged', 'E-PARSE', 'Inline [key] value pairs; passive object by index'),
    '[waiting action]': ('waiting_actions', 'paths', 'E-PARSE', 'Newmonsters action file'),
    '[move action]': ('move_actions', 'paths', 'E-PARSE', 'Newmonsters action file'),
    '[sit action]': ('sit_actions', 'paths', 'E-PARSE', 'Newmonsters action file'),
    '[damage action 1]': ('damage_actions_1', 'paths', 'E-PARSE', 'Newmonsters action file'),
    '[damage action 2]': ('damage_actions_2', 'paths', 'E-PARSE', 'Newmonsters action file'),
    '[down action]': ('down_actions', 'paths', 'E-PARSE', 'Newmonsters action file'),
    '[overturn action]': ('overturn_actions', 'paths', 'E-PARSE', 'Newmonsters action file'),
    '[attack action]': ('attack_actions', 'paths', 'E-PARSE', 'Aligned with [attack info] and [cooltime]'),
    '[last action]': ('last_actions', 'paths', 'E-PARSE', 'Newmonsters death action'),
    '[jump action]': ('jump_actions', 'paths', 'E-PARSE', 'Newmonsters action file'),
    '[dash action]': ('dash_actions', 'paths', 'E-PARSE', 'Newmonsters action file'),
    '[cooltime]': ('cooltimes', 'list', 'E-PARSE', 'Per-[attack action] cooldown, milliseconds (E-INFER)'),
    '[think term]': ('think_term', 'int', 'E-PARSE', 'AI think interval, milliseconds (E-INFER)'),
    '[vision]': ('vision', 'int', 'E-PARSE', 'Newmonsters sight range'),
    '[keep distance with target]': ('keep_distance', 'int', 'E-PARSE', 'Newmonsters preferred range'),
}
for res in ['fire', 'water', 'dark', 'light', 'freeze', 'slow', 'stun', 'stone', 'hold', 'poison', 'bleeding',
            'burn', 'lightning', 'curse', 'blind', 'confuse', 'sleep']:
    MOB_FIELDS[f'[{res} resistance]'] = (f'{res}_resistance', 'number', 'E-PARSE', '')
for motion in ['waiting', 'move', 'sit', 'damage motion 1', 'damage motion 2', 'down', 'overturn']:
    tag = f'[{motion} motion]' if 'motion' not in motion else f'[{motion}]'
    MOB_FIELDS[tag] = (key_of(tag), 'paths', 'E-PARSE', '')
OBJ_FIELDS = {
    '[width]': ('width', 'list', 'E-PARSE', ''),
    '[floating height]': ('floating_height', 'number', 'E-PARSE', ''),
    '[layer]': ('layer', 'str', 'E-PARSE', ''),
    '[pass type]': ('pass_type', 'str', 'E-PARSE', ''),
    '[piercing power]': ('piercing_power', 'int', 'E-PARSE', ''),
    '[basic motion]': ('basic_motion', 'paths', 'E-PARSE', ''),
    '[attack info]': ('attack_infos', 'paths', 'E-PARSE', ''),
    '[etc motion]': ('etc_motions', 'paths', 'E-PARSE', ''),
    '[etc attack info]': ('etc_attack_infos', 'paths', 'E-PARSE', ''),
    '[add object effect]': ('add_object_effect', 'list', 'E-PARSE', 'ANI path, layer'),
    '[destroy particle]': ('destroy_particle', 'paths', 'E-PARSE', ''),
    '[object destroy condition]': ('destroy_condition', 'list', 'E-PARSE', ''),
    '[int data]': ('int_data', 'list', 'E-PARSE', ''),
    '[string data]': ('string_data', 'list', 'E-PARSE', '破坏粒子路径与受击/破坏音效 key'),
    '[name]': ('name', 'list', 'E-PARSE', ''),
}
# PTL uses the ordered axis-aware decoder, not this flat tag table.
PTL_FIELDS = {}
ACT_FIELDS = {
    '[BASE ANI]': ('base_ani', 'path', 'E-PARSE', 'Motion ANI, relative to the .act file'),
    '[SUB ANI]': ('sub_ani', 'path', 'E-PARSE', 'Secondary layered ANI'),
    '[SOUND]': ('sound_keys', 'list', 'E-PARSE', 'Alternating sound key/frame values'),
}
FIELD_TABLES = {'atk': ATK_FIELDS, 'skl': SKL_FIELDS, 'chr': CHR_FIELDS, 'mob': MOB_FIELDS,
                'obj': OBJ_FIELDS, 'ptl': PTL_FIELDS, 'act': ACT_FIELDS}
ACTION_KEYS = ('waiting_actions', 'move_actions', 'sit_actions', 'damage_actions_1',
               'damage_actions_2', 'down_actions', 'overturn_actions', 'attack_actions',
               'last_actions', 'jump_actions', 'dash_actions')
# Passive objects spawned by the trial skills (engine code links them, not a script field).
SKILL_OBJECTS = ['passiveobject/character/swordman/gorecross.obj', 'passiveobject/character/swordman/momentaryslashwave.obj']
SKILL_EXTRA_ANIMATIONS = ['passiveobject/actionobject/monster/wooden_doll/animation/tombstonerain.ani']


def swordman_skill_asset_paths(lib: Library) -> dict[str, list[str]]:
    """Return the player-skill dependency closure visible in the source archive.

    SKL records do not carry an action graph: the client links skill IDs to CHR
    motions and passive objects. Compile every Swordman-owned motion/effect bank
    so the generated runtime adapter can reference those files without silently
    depending on a hand-maintained 16-skill allowlist.
    """
    patterns = {
        'ani': [
            'character/swordman/animation/%',
            'character/swordman/effect/animation/%',
            'passiveobject/character/swordman/animation/%',
        ],
        'atk': [
            'character/swordman/attackinfo/%',
            'character/swordman/dsattackinfo/%',
            'passiveobject/character/swordman/attackinfo/%',
        ],
        'ptl': [
            'character/swordman/particle/%',
            'character/swordman/effect/particle/%',
            'passiveobject/character/swordman/particle/%',
        ],
        'obj': ['passiveobject/character/swordman/%'],
    }
    found: dict[str, list[str]] = {}
    for extension, prefixes in patterns.items():
        values = set(SKILL_OBJECTS) if extension == 'obj' else set()
        for prefix in prefixes:
            rows = lib.db.execute(
                'select path from files where extension=? and lower(path) like ?',
                ('.' + extension, prefix),
            )
            for (path,) in rows:
                path = str(path).lower()
                if '[pvp]' in path:
                    continue
                if extension == 'obj' and not path.endswith('.obj'):
                    continue
                values.add(path)
        found[extension] = sorted(values)
    return found


def first(node: dict):
    return node['values'][0] if node['values'] else None


def decode_value(node: dict, shape: str, base_path: str):
    if shape == 'atk_integer':
        # PVF type-4 tokens have already been decoded as binary32 by dnf_pvf.
        # 1218A80 truncates those toward zero; type-2 integers keep all 32 bits.
        # This rule is proven for damage bonus only, not every numeric ATK tag.
        value = first(node)
        if type(value) not in (int, float) or not math.isfinite(value) or not -2147483648 <= value < 2147483648:
            raise ValueError(f'{base_path}: damage bonus outside verified signed integer domain')
        return int(value)
    if shape == 'enum':
        return [{'value': e['canonical'], 'raw': e['tag'], 'args': e['values']} for e in node.get('enum', [])] or None
    if shape in ('int', 'float', 'str', 'number'):
        return first(node)
    if shape == 'paths':
        return [resolve(base_path, v) if isinstance(v, str) and v else v for v in node['values']]
    if shape == 'path':
        value = first(node)
        return resolve(base_path, value) if isinstance(value, str) and value else value
    if shape == 'pairs':
        v = node['values']
        return [[v[i], v[i + 1]] for i in range(0, len(v) - 1, 2)]
    if shape == 'section':
        return {'present': True}
    if shape == 'tagged':
        out, key = {}, None
        for value in node['values']:
            if isinstance(value, str) and value.startswith('[') and value.endswith(']'):
                key = key_of(value)
                out[key] = None
            elif key is not None:
                out[key] = value if out[key] is None else (out[key] if isinstance(out[key], list) else [out[key]]) + [value]
        return out
    return node['values']


def flatten_nodes(nodes: list):
    for node in nodes:
        yield node
        yield from flatten_nodes(node.get('children', []))


def decode_fields(kind: str, fields: list, path: str) -> tuple[dict, dict, list]:
    if kind == 'ptl':
        return decode_particle_fields(fields, path)
    table = FIELD_TABLES[kind]
    decoded, evidence, unsupported = {}, {}, []
    chr_group = None
    if kind == 'act':
        # .act nests semantic fields under [MOTION]/[TRIGGER]/[BEHAVIOR]. Only the
        # stable action-asset fields needed by the runtime are decoded here; the
        # original nested tree remains available in `raw`.
        fields = list(flatten_nodes(fields))
    i = 0
    while i < len(fields):
        node = fields[i]
        tag = canonical(node['tag'])
        is_growth = tag.startswith('[growtype ') and tag[10:-1].isdigit()
        is_awakening = tag.startswith('[awakening ') and tag[11:-1].isdigit()
        if kind == 'chr' and (tag == '[initial value]' or is_growth or is_awakening):
            group = key_of(tag)
            if is_awakening:
                if chr_group is None:
                    unsupported.append({'tag': node['tag'], 'offset': node['offset'], 'reason': 'awakening has no preceding CHR group'})
                    stats, location = {}, None
                else:
                    stats = decoded['stat_groups'][chr_group].setdefault('awakenings', {}).setdefault(group, {})
                    location = 'stat_groups/' + chr_group + '/awakenings/' + group
            else:
                chr_group = group
                stats = decoded.setdefault('stat_groups', {}).setdefault(group, {})
                location = 'stat_groups/' + group
            i += 1
            while i < len(fields) and canonical(fields[i]['tag']) in STAT_TAGS + GROUP_EXTRAS:
                f = fields[i]
                stats[key_of(f['tag'])] = first(f) if len(f['values']) == 1 else f['values']
                i += 1
            if location is not None:evidence[location] = 'E-PARSE'
            continue
        if kind == 'chr' and tag == '[awakening name]':
            if chr_group is None:
                unsupported.append({'tag': node['tag'], 'offset': node['offset'], 'reason': 'awakening name has no preceding CHR group'})
            else:
                decoded['stat_groups'][chr_group]['awakening_name_refs'] = node['values']
                evidence['stat_groups/' + chr_group + '/awakening_name_refs'] = 'E-PARSE'
            i += 1
            continue
        if kind == 'chr' and tag in STAT_TAGS:
            unsupported.append({'tag': node['tag'], 'offset': node['offset'], 'reason': 'stat outside a group'})
            i += 1
            continue
        if tag not in table:
            if kind == 'act':
                i += 1
                continue
            unsupported.append({'tag': node['tag'], 'offset': node['offset'], 'reason': 'no decoder'})
            i += 1
            continue
        key, shape, ev, _ = table[tag]
        if shape == 'context':
            ctx = {}
            for child in node.get('children', []):
                ctx[key_of(child['tag'])] = child['values']
            decoded[key] = ctx
        elif shape == 'repeat_list':
            decoded.setdefault(key, []).append(node['values'])
        elif key in decoded and shape not in ('section',):
            value = decode_value(node, shape, path)
            decoded.setdefault(key + '_repeats', []).append(value)
            if kind == 'atk' and key == 'damage_bonus':
                # Each 12D044B field dispatch overwrites +24; raw retains order.
                decoded[key] = value
        else:
            decoded[key] = decode_value(node, shape, path)
        evidence[key] = ev
        if canonical(node['tag']) != node['tag'] or any(e['canonical'] != e['tag'] for e in node.get('enum', [])):
            evidence[key] = 'E-INFER'
        i += 1
    return decoded, evidence, unsupported


def record(lib: Library, path: str, kind: str) -> dict | None:
    script = lib.script(path, kind)
    if script is None:
        return None
    decoded, evidence, unsupported = decode_fields(kind, script['fields'], path)
    return {'id': path, 'kind': kind, 'raw': script['fields'], 'decoded': decoded, 'evidence': evidence,
            'unsupported': unsupported, 'diagnostics': script['diagnostics'],
            'source': {'path': path, 'sha256': script['sha256'], 'asset_version': lib.asset_version}}


def animation_record(lib: Library, path: str) -> dict | None:
    found = lib.animation(path)
    if found is None:
        return None
    meta = found['metadata'] or {}
    clock, timeline = 0, []
    for frame in meta.get('frames', []):
        delay = frame.get('delay_ms') or 0
        attack = [b['box'] for b in frame.get('boxes', []) if b['kind'] == 'attack']
        hurt = [b['box'] for b in frame.get('boxes', []) if b['kind'] == 'damage']
        timeline.append({'frame': frame['frame'], 'start_ms': clock, 'end_ms': clock + delay,
                         'attack_boxes': attack, 'damage_boxes': hurt, 'items': frame.get('items', {})})
        clock += delay
    return {'id': path, 'kind': 'ani', 'status': found['status'], 'error': found['error'],
            'decoded': {'duration_ms': meta.get('duration_ms'), 'frame_count': meta.get('frame_count'),
                        'global_items': meta.get('global_items', {}), 'sound_events': meta.get('sound_events', []),
                        'timeline': timeline},
            'evidence': {'timeline': 'E-PARSE', 'attack_boxes': 'E-PARSE', 'box_axes': 'E-INFER'},
            'unsupported': [], 'source': {'path': path, 'sha256': found['sha256'], 'asset_version': lib.asset_version}}


_CATALOG_CACHE: dict[str, list] | None = None


def catalog_motions(mob_path: str) -> list[str]:
    """从 monster_catalog.json 取该 mob 的动作 ANI 绝对路径（新版 mob 用）。"""
    global _CATALOG_CACHE
    if _CATALOG_CACHE is None:
        _CATALOG_CACHE = {}
        path = ROOT / 'game_dnf/data/monster_catalog.json'
        if path.is_file():
            for entry in json.loads(path.read_text(encoding='utf-8')).get('monsters', {}).values():
                folder = str(entry.get('folder', ''))
                for values in (entry.get('motions') or {}).values():
                    for value in values or []:
                        _CATALOG_CACHE.setdefault(str(entry.get('path', '')).lower(), []).append(
                            (folder + '/' + str(value)).lower())
    return _CATALOG_CACHE.get(mob_path.lower(), [])


def referenced_mob_paths() -> set[str]:
    """收集需要编译的 mob：地图房间引用的 + data/combat.json 里覆盖的（版本切换用）。"""
    dungeons_path = ROOT / 'game_dnf/data/dungeons.json'
    if not dungeons_path.is_file():
        return set()
    out: set[str] = set()
    # 版本切换后 combat.json 的 mob/stats_mob 可能指向地图里没有的路径（新版 mob）。
    combat_path = ROOT / 'game_dnf/data/combat.json'
    if combat_path.is_file():
        for value in json.loads(combat_path.read_text(encoding='utf-8')).get('monsters', {}).values():
            for field_name in ('mob', 'stats_mob'):
                target = str(value.get(field_name, '')).lower()
                if target:
                    out.add(target)
    dungeons = json.loads(dungeons_path.read_text(encoding='utf-8'))['dungeons']
    for spec in dungeons.values():
        export = spec.get('map_export', '')
        if not export:
            continue
        path = ROOT / 'game_dnf' / export.replace('res://', '')
        if not path.is_file():
            continue
        try:
            data = json.loads(path.read_text(encoding='utf-8'))
        except Exception:
            continue
        for room in (data.get('dungeon', {}).get('rooms') or {}).values():
            for monster in room.get('monsters') or []:
                mob = monster.get('mob')
                if mob:
                    out.add(str(mob).lower())
    return out


def referenced_breakable_objects() -> list[str]:
    """扫副本地图的 [passive object]，收集可破坏物（breakableobject/）的 .obj 路径。"""
    dungeons_path = ROOT / 'game_dnf/data/dungeons.json'
    if not dungeons_path.is_file():
        return []
    found: set[str] = set()
    dungeons = json.loads(dungeons_path.read_text(encoding='utf-8'))['dungeons']
    for spec in dungeons.values():
        export = spec.get('map_export', '')
        if not export:
            continue
        path = ROOT / 'game_dnf' / export.replace('res://', '')
        if not path.is_file():
            continue
        try:
            data = json.loads(path.read_text(encoding='utf-8'))
        except Exception:
            continue
        for room in (data.get('dungeon', {}).get('rooms') or {}).values():
            for obj in room.get('objects') or []:
                target = str(obj.get('obj', '')).lower()
                if not target.endswith('.obj'):
                    continue
                # 可破坏物 + 陷阱机关（trap/* 带 [attack info]，会伤害玩家）。
                if 'breakableobject/' in target or '/trap/' in target:
                    found.add(target)
    return sorted(found)


def compile_native_attack_emissions(mob: dict, mob_id: int, spec: dict, passive_index: dict, add) -> list[dict]:
    """Resolve pinned OBJ/ANI/ATK/PTL dependencies for a native MOB state handler."""
    path = mob['id']

    def checked(record: dict | None, dependency: str) -> dict:
        sha = spec['sha256'].get(dependency)
        if not sha or not record or record['source']['sha256'] != sha:
            raise ValueError(f'Native attack emission for {path} needs exact source {dependency}')
        return record

    checked(mob, path)
    if mob_id != spec['mob_id']:
        raise ValueError(f'Native attack emission for {path} has mismatched MOB ID')
    integers = mob['decoded'].get('int_data', [])
    attack_motions = mob['decoded'].get('attack_motions', [])
    attack_infos = mob['decoded'].get('attack_infos', [])
    rows = {}
    for binding in spec['slots']:
        slot, frame = binding['slot'], binding['frame']
        if not 0 <= slot < len(attack_motions) or slot in rows:
            raise ValueError(f'Native attack emission for {path} has invalid or duplicate attack slot {slot}')
        index, object_id = binding['object_int_index'], binding['object_id']
        if not 0 <= index < len(integers) or integers[index] != object_id:
            raise ValueError(f'Native attack emission for {path} has mismatched MOB int data in slot {slot}')
        relative_obj = passive_index.get(object_id)
        if not relative_obj:
            raise ValueError(f'Native attack emission for {path} cannot resolve OBJ{object_id} in the original LST')
        obj_path = ('passiveobject/' + relative_obj).lower()
        obj = checked(add(obj_path, 'obj', path), obj_path)['decoded']
        motions, attacks = obj.get('basic_motion', []), obj.get('attack_infos', [])
        if len(motions) != 1 or len(attacks) != 1:
            raise ValueError(f'Native attack emission for {path} needs a single OBJ basic ANI and ATK')
        projectile_ani = checked(add(motions[0], 'ani', obj_path), motions[0])
        if not any(row['attack_boxes'] for row in projectile_ani['decoded']['timeline']):
            raise ValueError(f'Native attack emission for {path} has no projectile attack boxes')
        checked(add(attacks[0], 'atk', obj_path), attacks[0])
        ani_path = attack_motions[slot]
        ani = checked(add(ani_path, 'ani', path), ani_path)
        if not any(row['frame'] == frame for row in ani['decoded']['timeline']):
            raise ValueError(f'Native attack emission for {path} has no frame {frame} in slot {slot}')
        if 'selection_source' in spec:
            if slot >= len(attack_infos) or not attack_infos[slot]:
                raise ValueError(f'Native attack selection for {path} needs the slot {slot} ATK')
            slot_atk = attack_infos[slot]
            atk = checked(add(slot_atk, 'atk', path), slot_atk)['decoded']
            teams = tuple(atk.get(key, 0) for key in ('attack_enemy', 'attack_friend', 'attack_myself'))
            if teams != (1, 0, 0):
                raise ValueError(f'Native attack selection for {path} needs hostile-only targeting in slot {slot}')
        ptl_path = binding['ptl_path']
        ptl = checked(add(ptl_path, 'ptl', path), ptl_path)
        if not ptl['decoded'] or ptl['unsupported'] or ptl['diagnostics']:
            raise ValueError(f'Native attack emission for {path} has uncompiled PTL {ptl_path}')
        rows[slot] = {'slot': slot, 'frame': frame, 'object_id': object_id, 'object_path': obj_path,
                      'ptl_path': ptl_path, 'offset': binding['offset'], 'sound': binding['sound']}
    return [rows[slot] for slot in sorted(rows)]


def compile_native_attack_selection(mob: dict, attack_slots: list[dict], source: dict) -> dict:
    """Compile the classic hostile slot poll for ordinary PvE targets."""
    path = mob['id']
    decoded = mob['decoded']
    attack_kind = decoded.get('attack_kind', [])
    delay = decoded.get('attack_delay', 0)
    # The native selector uses float32(delay * 0.2) and truncates. At the
    # supported MOB delay range below the result is exactly delay // 5.
    if len(attack_kind) % 12 or type(delay) is not int or not 5 <= delay <= 1000000:
        raise ValueError(f'Native attack selection for {path} has invalid row size or delay')
    if any(field['tag'] == '[keep distance]' for field in mob['raw']):
        raise ValueError(f'Native attack selection for {path} needs the original keep-distance offset')
    slots = []
    for offset in range(0, len(attack_kind), 12):
        standing, no_target, other, enabled, *area = attack_kind[offset:offset + 12]
        if enabled not in (0, 1) or any(type(value) is not int or value < 0 for value in area):
            raise ValueError(f'Native attack selection for {path} has invalid area or eligibility flag')
        if not enabled:
            continue
        if (other != 0 and 'alternate_target_class' not in source) or not all(
                0 <= chance <= 100 and int(chance) == chance for chance in (standing, no_target, other)):
            raise ValueError(f'Native attack selection for {path} uses unverified probability modes')
        row = {'slot': offset // 12, 'standing_percent': int(standing),
               'no_target_percent': int(no_target), 'area': area}
        if 'alternate_target_class' in source:
            row['alternate_target_percent'] = int(other)
        slots.append(row)
    if {row['slot'] for row in slots} != {row['slot'] for row in attack_slots}:
        raise ValueError(f'Native attack selection for {path} disagrees with its bound attack slots')
    return {'initial_ms': source['initial_ms'], 'down_gate_percent': source['down_gate_percent'],
            'delay_ms': delay, 'delay_spread_ms': delay // 5,
            'slots': slots, 'source': source}


def compile_native_attack_contact(mob: dict, mob_id: int, spec: dict, passive_index: dict, add) -> dict:
    """Bind an engine contact callback to its pinned original slot and attack object."""
    path = mob['id']

    def checked(record: dict | None, dependency: str) -> dict:
        if not record or record['source']['sha256'] != spec['sha256'].get(dependency):
            raise ValueError(f'Native attack contact for {path} needs exact source {dependency}')
        return record['decoded']

    decoded = checked(mob, path)
    if mob_id != spec['mob_id']:
        raise ValueError(f'Native attack contact for {path} has mismatched MOB ID')
    slot = spec['slot']
    motions = decoded.get('attack_motions', [])
    attacks = decoded.get('attack_infos', [])
    if not 0 <= slot < min(len(motions), len(attacks)):
        raise ValueError(f'Native attack contact for {path} has no complete attack slot {slot}')
    attack_ani = checked(add(motions[slot], 'ani', path), motions[slot])
    checked(add(attacks[slot], 'atk', path), attacks[slot])
    object_id = spec['object_id']
    relative_obj = passive_index.get(object_id)
    if not relative_obj:
        raise ValueError(f'Native attack contact for {path} cannot resolve OBJ{object_id} in the original LST')
    obj_path = ('passiveobject/' + relative_obj).lower()
    obj = checked(add(obj_path, 'obj', path), obj_path)
    if len(obj.get('basic_motion', [])) != 1 or len(obj.get('attack_infos', [])) != 1:
        raise ValueError(f'Native attack contact for {path} needs a single OBJ basic ANI and ATK')
    obj_ani = obj['basic_motion'][0]
    obj_atk = obj['attack_infos'][0]
    bolt_ani = checked(add(obj_ani, 'ani', obj_path), obj_ani)
    checked(add(obj_atk, 'atk', obj_path), obj_atk)
    if not all(any(row['attack_boxes'] for row in ani['timeline']) for ani in (attack_ani, bolt_ani)):
        raise ValueError(f'Native attack contact for {path} needs both original attack timelines')
    return {'slot': slot, 'object_id': object_id, 'object_path': obj_path,
            'object_bank': spec['object_bank'], 'target_class': spec['target_class'],
            'chance_percent': spec['chance_percent'], 'source': spec['source']}


def checked_zealot_source(record: dict | None, path: str, hashes: dict) -> dict:
    if not record or record['source']['sha256'] != hashes.get(path):
        raise ValueError(f'Native Zealot or StarFish binding needs exact source {path}')
    return record['decoded']


def compile_native_raxy_suicide(mob: dict, mob_id: int, monster_index: dict, add) -> dict:
    path = mob['id']
    decoded = checked_zealot_source(mob, path, NATIVE_RAXY_SOURCE)
    if mob_id != 260 or not decoded.get('etc_motions'):
        raise ValueError('Native Raxy binding needs original MOB260 and [etc motion] 0')
    suicide_ani = decoded['etc_motions'][0]
    clip = checked_zealot_source(add(suicide_ani, 'ani', path), suicide_ani, NATIVE_RAXY_SOURCE)
    timeline = clip['timeline']
    if not any(frame['frame'] == 2 for frame in timeline) or any(frame['attack_boxes'] for frame in timeline):
        raise ValueError('Native Raxy suicide must have its original sound frame and no attack boxes')
    for monster_path, spec in NATIVE_STARFISH_JUMPS.items():
        actual = monster_index.get(spec['mob_id'], '')
        if ('monster/' + actual).lower() != monster_path:
            raise ValueError(f'Native Raxy summon index differs for MOB{spec["mob_id"]}')
        checked_zealot_source(add(monster_path, 'mob', path), monster_path, spec['sha256'])
    return {
        'chance': [5, 300], 'state': 18, 'etc_motion_index': 0, 'suicide_ani': suicide_ani,
        'sound_frame': 2, 'sound': 'KNIFE_STICK',
        'spawn': {
            'monster_ids': [250, 252], 'count_min': 2, 'count_span': 2,
            'offset_x': [-20, 19], 'offset_y': [-10, 9], 'offset_z': 20,
            'launch_x': [100, 299], 'launch_y': [50, 149], 'launch_height': [40, 99],
            'launch_state': 10, 'gravity_mode': 2, 'ground_gravity': -1500, 'sound': 'ZGM_SPRING',
            'launch_x_direction_codes': [0, 1], 'launch_y_direction_codes': [2, 3],
        },
        'source': {
            'engine_sha256': NATIVE_ZEALOT_SOURCE_SHA, 'selection': '0xDBA980', 'animation': '0x269CAFE',
            'finish': '0xDBCFA0', 'spawn': '0xDBC180 → 0x2688815 → 0x86E090',
            'receive': '0xE5BA9D → 0x87B690', 'launch': '0x876A20', 'room_gate': '0x8A06B0',
        },
    }


def compile_native_starfish_jump(mob: dict, mob_id: int, spec: dict, add) -> dict:
    path = mob['id']
    hashes = spec['sha256'] | NATIVE_STARFISH_ATTACKS
    decoded = checked_zealot_source(mob, path, hashes)
    motions = decoded.get('attack_motions', [])
    attacks = decoded.get('attack_infos', [])
    etc_motions = decoded.get('etc_motions', [])
    etc_atk_nodes = find(mob['raw'], '[etc attack info]')
    if mob_id != spec['mob_id'] or min(len(motions), len(attacks)) < 2 or len(etc_motions) < 4 or len(etc_atk_nodes) != 1:
        raise ValueError(f'Native StarFish {path} lacks original slot 1 or ETC bindings')
    etc_attacks = decode_value(etc_atk_nodes[0], 'paths', path)
    if len(etc_attacks) < 2:
        raise ValueError(f'Native StarFish {path} lacks ETC attack index 1')
    start_ani, rolling_ani, end_ani = motions[1], etc_motions[2], etc_motions[3]
    for dependency in (start_ani, rolling_ani, end_ani):
        checked_zealot_source(add(dependency, 'ani', path), dependency, hashes)
    for dependency in (attacks[1], etc_attacks[1]):
        checked_zealot_source(add(dependency, 'atk', path), dependency, hashes)
    for dependency in etc_attacks:
        if dependency:
            add(dependency, 'atk', path)
    selection = compile_native_attack_selection(mob, [
        {'slot': index} for index, (motion, attack) in enumerate(zip(motions, attacks, strict=True))
        if motion and attack
    ], {
        'initial_ms': 3000, 'down_gate_percent': 0,
        'target_class': 0x11, 'alternate_target_class': 0x21,
        'normal_ai_call': '0x8782ED', 'attempt_deadline': '0x8837DE..0x88384F',
        'target_area': '0x877CE0', 'slot_probabilities': '0x8784D0..0x8786FC',
        'no_target_probability': '0x878710..0x87875A', 'uniform_candidate': '0x8838FB..0x88394E',
    })
    return {
        'slot': 1, 'state': 8, 'start_ani': start_ani, 'rolling_ani': rolling_ani, 'end_ani': end_ani,
        'rolling_atk': etc_attacks[1], 'rolling_etc_motion_index': 2, 'end_etc_motion_index': 3,
        'rolling_etc_attack_index': 1, 'launch_frame': 1, 'forward_speed': 80,
        'jump_height': 150, 'roll_above_z': 130, 'end_below_z': 15, 'gravity': -1500, 'sound': 'ZGM_ATK',
        'selection': selection,
        'source': {'engine_sha256': NATIVE_ZEALOT_SOURCE_SHA, 'entry': '0xDB75D0', 'update': '0xDB5270'},
    }


def compile_native_starfish_bite(mob: dict, add) -> dict:
    path = mob['id']
    decoded = checked_zealot_source(mob, path, NATIVE_STARFISH_JUMPS[path]['sha256'])
    attempt_ani = decoded['attack_motions'][0]
    bite_ani, release_ani = decoded['etc_motions'][:2]
    attempt_atk = decoded['attack_infos'][0]
    bite_atk = decode_value(find(mob['raw'], '[etc attack info]')[0], 'paths', path)[0]
    for dependency in (attempt_ani, bite_ani, release_ani):
        checked_zealot_source(add(dependency, 'ani', path), dependency, NATIVE_STARFISH_BITE)
    for dependency in (attempt_atk, bite_atk):
        checked_zealot_source(add(dependency, 'atk', path), dependency, NATIVE_STARFISH_BITE)
    return {
        'slot': 0, 'attempt_ani': attempt_ani, 'attempt_atk': attempt_atk,
        'bite_ani': bite_ani, 'bite_atk': bite_atk, 'release_ani': release_ani,
        'launch_frame': 1, 'forward_speed': 200, 'jump_height': 120, 'gravity': -1500,
        'release_speed': 200, 'release_height': 10,
        'level_range': decoded['level'], 'count_range': decoded['int_data'], 'attach_sound': 'ZGM_ATTACH',
        # DB4D42 applies the class-0 Swordman anchor, with X mirrored by facing.
        'swordman_anchor': [5, 1, 75],
        'source': {
            'engine_sha256': NATIVE_ZEALOT_SOURCE_SHA, 'attempt': '0xDB3CC0',
            'contact': '0xDB5E60', 'bite': '0xDB69A0', 'count': '0xDB5CE0 → 0x11AEE50',
            'release': '0xDB60F0 / 0xDB3EA0 → 0xDB4530',
        },
    }


def compile_native_outerwall_breakables(passive_index: dict, add) -> None:
    for source_id, (obj_name, ani_name, ptl_name, obj_sha, ani_sha, ptl_sha) in NATIVE_OUTERWALL_BREAKABLES.items():
        path = OUTERWALL_BREAKABLE_ROOT + obj_name + '.obj'
        motion = OUTERWALL_BREAKABLE_ROOT + 'animation/' + ani_name + '.ani'
        particle = OUTERWALL_BREAKABLE_ROOT + 'particle/' + ptl_name + '.ptl'
        hashes = {path: obj_sha, motion: ani_sha, particle: ptl_sha}
        indexed = passive_index.get(source_id, '').replace('\\', '/').lower()
        if 'passiveobject/' + indexed != path:
            raise ValueError(f'Original OBJ{source_id} must resolve to {path}')
        obj, ani, ptl = (add(source, kind, path) for source, kind in ((path, 'obj'), (motion, 'ani'), (particle, 'ptl')))
        if any(not row or row['source']['sha256'] != digest for row, digest in zip((obj, ani, ptl), hashes.values())):
            raise ValueError(f'Original breakable source changed: {path}')
        fields = obj['decoded']
        integers, strings = fields['int_data'], fields['string_data']
        if (fields['basic_motion'] != [motion] or len(integers) != 7 or len(strings) != 6
                or resolve(path, strings[2]) != particle or ptl['unsupported']
                or ptl['decoded']['object_type'] != '[animation]'
                or not any(frame['damage_boxes'] for frame in ani['decoded']['timeline'])):
            raise ValueError(f'Original breakable fields or hit boxes changed: {path}')
        for entry in ptl['decoded']['object_entries']:
            animation = entry['path']
            row = add(animation, 'ani', particle) if entry['parameter'] == -1 else None
            if not row or not row['decoded']['timeline']:
                raise ValueError(f'Original breakable particle animation missing: {animation}')
            hashes[animation] = row['source']['sha256']
        obj['native_breakable'] = {
            'object_index': source_id, 'motion_ani': motion, 'destroy_particle': particle,
            'particle_offset': integers[3:6], 'hp': integers[6],
            'trigger_stage': integers[0], 'stages': integers[1], 'destroy_on_final_stage': bool(integers[2]),
            'hit_sound': strings[4], 'destroy_sound': strings[5], 'source_hashes': hashes,
            'source': {'engine_sha256': NATIVE_ZEALOT_SOURCE_SHA, 'factory': '0xA1CF36',
                       'initialize': '0xA38DB0', 'damage': '0x7FAEB7..0x7FAF85',
                       'stage': '0xA36600', 'destroy': '0xA368D0'},
        }


def native_jar_gas_poison(lib: Library, attack: dict) -> dict:
    fields = {}
    for path, digest in NATIVE_JAR_GAS_SHA.items():
        script = lib.script(path)
        if not script or script['sha256'] != digest:
            raise ValueError('Original jar poison source changed: ' + path)
        fields[path] = {row['tag']: row['values'] for row in script['fields']}
    custom = 6  # The DGN21 trap MAP rows pass this value to OBJ48003.
    basis_level, = fields[NATIVE_JAR_GAS_DUNGEON]['[basis level]']
    status = fields[NATIVE_JAR_GAS_STATUS_TABLE]
    max_level, = status['[active status max level]']
    low, high = status['[active status etc parameters]'][16:18]
    poison, = (row for row in attack['active_status'] if row['value'] == '[poison]')
    return {
        'custom': custom, 'chance_percent': poison['args'][0], 'basis_level': basis_level,
        'duration_ms': status['[active status duration]'][2] * 1000,
        'total_damage': int(low + (high - low) * (custom - 1) / (max_level - 1)),
    }


def compile_native_jar_traps(lib: Library, passive_index: dict, add) -> None:
    def require(path: str, origin: str) -> dict:
        row = add(path, path.rsplit('.', 1)[1], origin)
        if not row or row['source']['sha256'] != NATIVE_JAR_TRAP_SHA.get(path):
            raise ValueError('Original jar trap source changed: ' + path)
        return row

    warning = require(NATIVE_JAR_TRAP_WARNING, 'OBJ771 trap warning')
    rate_script = lib.script(NATIVE_JAR_TRAP_RATE)
    if not rate_script or rate_script['sha256'] != NATIVE_JAR_TRAP_SHA[NATIVE_JAR_TRAP_RATE]:
        raise ValueError('Original jar trap difficulty table changed')
    rates, = (row['values'] for row in rate_script['fields'] if row['tag'] == '[COMMON TRAP EXPLOSION]')
    base_duration = warning['decoded']['duration_ms']
    if rates != [100, 130, 160, 190] or base_duration != 1991:
        raise ValueError('Original jar trap warning timing changed')
    warning['native_trap_warning'] = {
        'base_duration_ms': base_duration, 'rate_percent': rates,
        'duration_ms': [base_duration * 100 // rate for rate in rates],
        'scale': warning['decoded']['timeline'][0]['items']['7'],
        'rate_source': NATIVE_JAR_TRAP_RATE,
        'rate_sha256': rate_script['sha256'],
    }

    for path, (source_ids, kind) in NATIVE_JAR_TRAP_OBJECTS.items():
        if any(resolve('passiveobject/passiveobject.lst', passive_index.get(source_id, '')) != path
               for source_id in source_ids):
            raise ValueError('Original jar trap LST entry changed: ' + path)
        obj = require(path, 'OBJ771 trap dispatch')
        fields = obj['decoded']
        motion, = fields['basic_motion']
        attack, = fields['attack_infos']
        motion_record = require(motion, path)
        attack_record = require(attack, path)
        motion_data = motion_record['decoded']
        timeline = motion_data['timeline']
        if not timeline or any(not frame['attack_boxes'] for frame in timeline):
            raise ValueError('Original jar trap collision motion missing: ' + motion)

        strings = fields['string_data']
        extras = fields.get('etc_motions', [])
        destroy = [resolve(path, item) for item in strings[6:8]] if extras else []
        particles = [] if extras else [resolve(path, item) for item in strings]
        hashes = {row['id']: row['source']['sha256'] for row in (obj, motion_record, attack_record)}
        for particle in particles:
            ptl = require(particle, path)
            if ptl['unsupported'] or ptl['decoded']['object_type'] != '[animation]':
                raise ValueError('Unresolved original jar trap emitter: ' + particle)
            hashes[particle] = ptl['source']['sha256']
            for entry in ptl['decoded']['object_entries']:
                ani = require(entry['path'], particle)
                if entry['parameter'] != -1 or any(frame['attack_boxes'] for frame in ani['decoded']['timeline']):
                    raise ValueError('Unexpected original jar trap particle child: ' + entry['path'])
                hashes[ani['id']] = ani['source']['sha256']
        for animation in extras + destroy:
            hashes[animation] = require(animation, path)['source']['sha256']
        obj['native_trap'] = {
            'source_ids': list(source_ids), 'kind': kind, 'motion_ani': motion, 'attack': attack,
            'attack_window_ms': None if extras else motion_data['duration_ms'],
            'floating_height': fields.get('floating_height', 0), 'particles': particles,
            'spawn_sound': 'TINGKERBELL_FLOAT_LOOP' if extras else {'poison': 'CLOUD_KILL_LOOP'}.get(kind, ''),
            'hit_sound': attack_record['decoded'].get('hit_wav', ''),
            'consume_sound': {'hpmp_fairy': 'TINGKERBELL_ALL_ABSORB',
                              'invincibility_fairy': 'TINGKERBELL_HP_ABSORB'}.get(kind, ''),
            'extra_animations': extras, 'destroy_animations': destroy, 'source_hashes': hashes,
        }
        if kind == 'poison':
            hashes.update(NATIVE_JAR_GAS_SHA)
            obj['native_trap']['poison'] = native_jar_gas_poison(lib, attack_record['decoded'])


def compile_native_poison_visual(add) -> None:
    for path, digest in NATIVE_POISON_VISUAL_SHA.items():
        row = add(path, path.rsplit('.', 1)[1], 'native poison status visual')
        if not row or row['source']['sha256'] != digest:
            raise ValueError('Original poison status visual source changed: ' + path)
        if path == NATIVE_POISON_PARTICLE:
            particle = row
        elif not row['decoded']['timeline'] or any(frame['attack_boxes'] for frame in row['decoded']['timeline']):
            raise ValueError('Invalid original poison status visual animation: ' + path)
    expected = [{'path': path, 'parameter': -1} for path in NATIVE_POISON_VISUAL_SHA
                if path != NATIVE_POISON_PARTICLE]
    if (particle['unsupported'] or particle['decoded']['object_type'] != '[animation]'
            or particle['decoded']['object_entries'] != expected):
        raise ValueError('Unresolved original poison status particle dependencies')
    particle['native_status_visual'] = {
        'particle': NATIVE_POISON_PARTICLE, 'z_offset': 70,
        'tint': {'argb': 0xFFFF00FF, 'period_ms': 700, 'alpha_amplitude': 25,
                 'alpha_base_default': 50, 'alpha_base_age_type_2': 30},
        'source': {'engine_sha256': NATIVE_ZEALOT_SOURCE_SHA,
                   'particle_dispatch': '0x8AE925..0x8AE965', 'tint_dispatch': '0x8B1C47..0x8B1CE7',
                   'source_hashes': NATIVE_POISON_VISUAL_SHA},
    }


def compile_scope(lib: Library, *, extra_mob_paths: tuple[str, ...] = ()) -> dict:
    records: dict[str, dict] = {}
    missing: list[dict] = []

    def add(path: str, kind: str, origin: str) -> dict | None:
        path = path.lower()
        if path in records:
            return records[path]
        rec = animation_record(lib, path) if kind == 'ani' else record(lib, path, kind)
        if rec is None:
            missing.append({'id': path, 'kind': kind, 'referenced_by': origin})
            return None
        records[path] = rec
        return rec

    chr_path = 'character/swordman/swordman.chr'
    swordman = add(chr_path, 'chr', 'scope')
    d = swordman['decoded']
    for key in ['attack_infos', 'jumpattack_info', 'dashattack_info', 'etc_attack_infos']:
        for p in d.get(key) or []:
            if p:add(p, 'atk', chr_path)
    for key, value in d.items():
        if 'motion' in key:
            for p in value or []:
                if isinstance(p, str) and p.endswith('.ani'):add(p, 'ani', chr_path)
    skills = lib.listing('skill/swordmanskill.lst')
    skill_index = {}
    for index, rel in sorted(skills.items()):
        p = ('skill/' + rel).lower()
        if add(p, 'skl', 'skill/swordmanskill.lst'):
            skill_index[str(index)] = p
    swordman_assets = swordman_skill_asset_paths(lib)
    for extension in ['ani', 'atk', 'ptl']:
        for value in swordman_assets[extension]:
            add(value, extension, 'swordman skill dependency closure')
    for value in SKILL_EXTRA_ANIMATIONS:
        add(value, 'ani', 'swordman skill adapter')
    for value in swordman_assets['obj']:
        obj = add(value, 'obj', 'swordman skill dependency closure')
        if not obj:
            continue
        od = obj['decoded']
        for key in ['basic_motion', 'etc_motions', 'destroy_particle']:
            for dependency in od.get(key) or []:
                if not isinstance(dependency, str) or not dependency:
                    continue
                kind = 'ani' if dependency.endswith('.ani') else 'ptl'
                add(dependency, kind, value)
        for key in ['attack_infos', 'etc_attack_infos']:
            for dependency in od.get(key) or []:
                if dependency:
                    add(str(dependency), 'atk', value)
        effect = od.get('add_object_effect') or []
        if effect and isinstance(effect[0], str):
            add(resolve(value, effect[0]), 'ani', value)
    # 地图上的可破坏物与陷阱机关：血量/破坏粒子/音效都在 .obj 里，
    # 不编进内容包运行时只能当静态美术画着（打不碎、也不会伤人）。
    for path in referenced_breakable_objects():
        obj = add(path, 'obj', 'map [passive object]')
        # 陷阱的伤害走 [attack info] → .atk；obj 不会像 mob 那样自动递归，这里手动补。
        # 注意 decode 阶段 paths 字段已经解析成绝对路径，不能再 resolve 一次。
        if obj:
            for rel in obj['decoded'].get('attack_infos') or []:
                if rel:
                    add(str(rel), 'atk', path)
    monsters = lib.listing('monster/monster.lst')
    monster_index = {}
    object_paths: list[str] = list(SKILL_OBJECTS)
    object_index: dict[str, str] = {}
    # 编译范围：哥布林家族 + 早期手写四只 + **副本实际引用到的全部 mob**。
    # 只认硬编码范围会让天空之城/桑德兰那批怪在内容包里查不到，运行时整只怪被跳过。
    extra = {path.lower() for path in extra_mob_paths}
    required = extra | NATIVE_ATTACK_CONTACTS.keys() | set(NATIVE_ZEALOT_MONSTERS.values()) | set(NATIVE_OUTERWALL_BANKS.values())
    needed = referenced_mob_paths() | required
    passive_objects = lib.listing('passiveobject/passiveobject.lst')
    compile_native_outerwall_breakables(passive_objects, add)
    compile_native_jar_traps(lib, passive_objects, add)
    compile_native_poison_visual(add)
    for index, rel in sorted(monsters.items()):
        p = ('monster/' + rel).lower()
        if not (p.startswith('monster/goblin/') or p in {
                'monster/tau/tauarmy.mob','monster/tau/taubeast.mob',
                'monster/lugaru/lugaru.mob','monster/lugaru/kurogaru.mob'} or p in needed):
            continue
        mob = add(p, 'mob', 'monster/monster.lst')
        if not mob:
            continue
        monster_index[str(index)] = p
        md = mob['decoded']
        def located(name: str) -> str:
            """mob 里的引用有两种写法：完整的库路径，或相对 mob 目录的路径。"""
            candidate = str(name).replace('\\', '/').lower()
            return candidate if lib.exists(candidate) else resolve(p, name)

        for p2 in md.get('attack_infos') or []:
            if p2:add(located(p2), 'atk', p)
        for key, value in md.items():
            if 'motion' in key:
                for p2 in value or []:
                    if isinstance(p2, str) and p2.endswith('.ani'):add(located(p2), 'ani', p)
        action_paths: list[str] = []
        for key in ACTION_KEYS:
            for action_path in md.get(key) or []:
                if not action_path:
                    continue
                act = add(located(action_path), 'act', p)
                if not act:
                    continue
                action_paths.append(str(act['id']))
                base_ani = str(act['decoded'].get('base_ani', ''))
                if base_ani:
                    add(base_ani, 'ani', act['id'])
        # 新版 mob 的动作在 [* action] 指向的 .act；若旧文件没有该字段，
        # 再从 catalog 的 [BASE ANI] 反推结果补一次，兼容更早的 newmonsters 变体。
        if not action_paths and not any('motion' in key for key in md):
            for rel in catalog_motions(p):
                add(rel, 'ani', p)
        throw = md.get('throw_attack') or {}
        if throw.get('passive_object_filename'):
            name = str(throw['passive_object_filename'])
            # Some mobs write archive-root paths here; prefer the script-relative one when it exists.
            relative = resolve(p, name)
            add(relative if lib.exists(relative) else name.replace('\\', '/').lower(), 'ptl', p)
        if throw.get('passive_object_index') is not None:
            obj_rel = passive_objects.get(int(throw['passive_object_index']))
            if obj_rel:
                object_paths.append(('passiveobject/' + obj_rel).lower())
                object_index[str(throw['passive_object_index'])] = object_paths[-1]
            else:
                missing.append({'id': str(throw['passive_object_index']), 'kind': 'obj_index', 'referenced_by': p})
        if p in NATIVE_ATTACK_EMISSIONS:
            spec = NATIVE_ATTACK_EMISSIONS[p]
            emissions = compile_native_attack_emissions(mob, index, spec, passive_objects, add)
            mob['native_attack_emissions'] = emissions
            mob['native_attack_emission_source'] = spec['source']
            if 'selection_source' in spec:
                mob['native_attack_selection'] = compile_native_attack_selection(mob, emissions, spec['selection_source'])
            for emission in emissions:
                object_index[str(emission['object_id'])] = emission['object_path']
        if p in NATIVE_ATTACK_CONTACTS:
            contact = compile_native_attack_contact(mob, index, NATIVE_ATTACK_CONTACTS[p], passive_objects, add)
            mob['native_attack_contacts'] = [contact]
            object_index[str(contact['object_id'])] = contact['object_path']
        if p == NATIVE_ZEALOT_MONSTERS['native_raxy']:
            mob['native_suicide'] = compile_native_raxy_suicide(mob, index, monsters, add)
        if p in NATIVE_STARFISH_JUMPS:
            mob['native_starfish_jump'] = compile_native_starfish_jump(mob, index, NATIVE_STARFISH_JUMPS[p], add)
        if p == NATIVE_ZEALOT_MONSTERS['native_starfish']:
            mob['native_starfish_bite'] = compile_native_starfish_bite(mob, add)
    unresolved_mobs = required - set(monster_index.values())
    if unresolved_mobs:
        raise ValueError('Required MOB paths missing from the original index or archive: ' + ', '.join(sorted(unresolved_mobs)))
    for mob_id, (_key, path, sha) in NATIVE_OUTERWALL_MOBS.items():
        if monster_index.get(str(mob_id)) != path or records[path]['source']['sha256'] != sha:
            raise ValueError(f'Native Outerwall MOB{mob_id} needs exact source {path}')
    for p in object_paths:
        obj = add(p, 'obj', 'scope')
        if not obj:
            continue
        od = obj['decoded']
        for key in ['basic_motion', 'etc_motions', 'destroy_particle']:
            for p2 in od.get(key) or []:
                if isinstance(p2, str) and p2:add(p2, 'ani' if p2.endswith('.ani') else 'ptl', p)
        for key in ['attack_infos', 'etc_attack_infos']:
            for p2 in od.get(key) or []:
                if p2:add(p2, 'atk', p)
        effect = od.get('add_object_effect') or []
        if effect and isinstance(effect[0], str):add(resolve(p, effect[0]), 'ani', p)
    return {'records': records, 'missing': missing,
            'indexes': {'swordman_skills': skill_index, 'monsters_goblin': monster_index, 'passive_objects': object_index}}


def coverage(lib: Library, handled: dict) -> dict:
    """Whole-archive field census for ATK/SKL/CHR/MOB, with decoder and runtime handler status."""
    report = {}
    for kind in ['atk', 'skl', 'chr', 'mob']:
        counts, files_with = Counter(), Counter()
        files = 0
        for path, content in lib.files('.' + kind):
            from dnf_pvf import parse_script
            try:
                parsed = parse_script(content, lib.strings, kind)
            except ValueError:
                continue
            files += 1
            seen = set()
            stack = list(parsed['fields'])
            while stack:
                node = stack.pop()
                tag = canonical(node['tag'])
                counts[tag] += 1
                seen.add(tag)
                for e in node.get('enum', []):
                    counts[tag + ' = ' + e['canonical']] += 1
                stack.extend(node.get('children', []))
            for tag in seen:
                files_with[tag] += 1
        table = FIELD_TABLES[kind]
        rows = []
        for tag, n in counts.most_common():
            if ' = ' in tag:
                continue
            decoder = table.get(tag)
            key = decoder[0] if decoder else None
            if kind == 'chr' and not decoder and (tag in STAT_TAGS + GROUP_EXTRAS or tag == '[initial value]'
                                                  or tag.startswith(('[growtype ', '[awakening '))):
                key, decoder = 'stat_groups', (None, None, 'E-PARSE', '')
            rows.append({'tag': tag, 'occurrences': n, 'files': files_with[tag],
                         'decoded_as': key, 'evidence': decoder[2] if decoder else None,
                         'runtime': handled.get(kind, {}).get(key, 'none') if key else 'none'})
        enums = defaultdict(dict)
        for tag, n in counts.items():
            if ' = ' in tag:
                parent, value = tag.split(' = ', 1)
                enums[parent][value] = n
        report[kind] = {'files': files, 'distinct_tags': len(rows), 'fields': rows, 'enum_values': enums,
                        'decoded_tags': sum(1 for r in rows if r['decoded_as']),
                        'runtime_handled_tags': sum(1 for r in rows if r['runtime'] != 'none')}
    return report


def run(library: Path | None, output: Path, *, extra_mob_paths: tuple[str, ...] = ()) -> dict:
    lib = open_library(library)
    try:
        scope = compile_scope(lib, extra_mob_paths=extra_mob_paths)
        handled = json.loads(HANDLED_FILE.read_text(encoding='utf-8')) if HANDLED_FILE.is_file() else {}
        cov = coverage(lib, handled)
        compiler_sources = [Path(__file__), ROOT / 'tools/dnf_pvf.py', ROOT / 'tools/dnf_particle_fields.py']
        compiler_sha = hashlib.sha256(b''.join(p.read_bytes().replace(b'\r\n', b'\n') for p in compiler_sources)).hexdigest()
        pack = {'schema': SCHEMA, 'compiler_version': COMPILER_VERSION, 'compiler_sha256': compiler_sha,
                'asset_version': lib.asset_version,
                'scope': 'swordman chr + reachable atk/ani + swordman skills; goblin-family monsters',
                'config_provenance': '111Script.pvf backup archive; runtime-effective PVF unconfirmed (DNF-D001)',
                'indexes': scope['indexes'], 'missing_references': scope['missing'],
                'records': dict(sorted(scope['records'].items()))}
        output.mkdir(parents=True, exist_ok=True)
        body = json.dumps(pack, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
        (output / 'combat_content.json').write_text(body, encoding='utf-8')
        cov_doc = {'schema': 'dnf_field_coverage/1', 'asset_version': lib.asset_version, 'kinds': cov}
        (output / 'field_coverage.json').write_text(json.dumps(cov_doc, ensure_ascii=False, indent=1, sort_keys=True), encoding='utf-8')
        kinds = Counter(r['kind'] for r in scope['records'].values())
        summary = {'records': dict(kinds), 'missing_references': len(scope['missing']),
                   'pack_sha256': hashlib.sha256(body.encode('utf-8')).hexdigest(),
                   'unsupported_in_scope': sum(len(r['unsupported']) for r in scope['records'].values()),
                   'coverage': {k: {'files': v['files'], 'tags': v['distinct_tags'], 'decoded': v['decoded_tags'],
                                    'runtime': v['runtime_handled_tags']} for k, v in cov.items()}}
        (output / 'compile_summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=1), encoding='utf-8')
        return summary
    finally:
        lib.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--library', type=Path, help='Full extraction library; defaults to the shared cache')
    parser.add_argument('--output', type=Path, default=OUT)
    parser.add_argument('--extra-mob', action='append', default=[], help='Include an original MOB path in a scratch output')
    args = parser.parse_args()
    output = args.output.resolve()
    if args.extra_mob and output == OUT.resolve():
        parser.error('--extra-mob requires a separate --output directory')
    summary = run(args.library, output, extra_mob_paths=tuple(args.extra_mob))
    print(json.dumps(summary, ensure_ascii=True, indent=1))


if __name__ == '__main__':
    sys.exit(main())
