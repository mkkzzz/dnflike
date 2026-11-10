"""Ordered PTL decoding, grounded in native reader 0x1310C60.

The checked client keeps an axis selector (default X); only move type and
variables 1/2 use it. Changing term/type and gravity are global fields.
Native generator 0xE4E170 distinguishes relative ANI files (parameter -1),
direct image-manager lookups (other parameters), and passive-object IDs.
Units, random distribution and simulation remain unestablished here.
Callers retain the ordered raw tree, including original object names.
"""
from __future__ import annotations

from copy import deepcopy
from dnf_pvf import resolve

AXES = {"[x axis]": "x", "[y axis]": "y", "[z axis]": "z"}
MOVE_TYPES = {"[stop]", "[straight line]", "[sin]", "[cos]"}
AXIS_FIELDS = {
    "[move type]": ("move_type", 1, str),
    "[move variable 1]": ("move_variable_1", 2, int),
    "[move variable 2]": ("move_variable_2", 2, int),
}
# Each tuple is (output name, arity, accepted scalar types). Keep original enums.
GLOBAL_FIELDS = {
    "[creation pos]": ("creation_pos", 3, int),
    "[changing term]": ("changing_term", 1, int),
    "[changing type]": ("changing_type", 1, str),
    "[gravity]": ("gravity", 1, int),
    "[rotation angle]": ("rotation_angle", 3, int),
    "[life time]": ("life_time", 1, int),
    "[landing type]": ("landing_type", 1, str),
    "[transparent value]": ("transparent_value", 2, int),
    "[creation frequency]": ("creation_frequency", 1, (int, float)),
    "[maximum create number]": ("maximum_create_number", 1, int),
    "[maximum create time]": ("maximum_create_time", 1, int),
    "[create area rotation angle]": ("create_area_rotation_angle", 3, int),
    "[create pos correct]": ("create_pos_correct", 1, int),
    "[how to create object]": ("how_to_create_object", 1, str),
    "[start sound]": ("start_sound", 1, str),
    "[create area size]": ("create_area_size", 3, int),
    "[rotation angle range type]": ("rotation_angle_range_type", 1, str),
    "[rotation angle variable]": ("rotation_angle_variable", 2, int),
    "[random range]": ("random_range", 1, int),
    "[display effect rate]": ("display_effect_rate", 3, int),
    "[object type]": ("object_type", 1, str),
}


def decode_particle_fields(fields: list, path: str) -> tuple[dict, dict, list]:
    """Preserve separate axes, source ordering, duplicate objects and raw parameters.

    Scalar writes and repeated [object] blocks replace previous values, as in
    the native reader; every original occurrence remains in the caller's raw.
    Unsupported field shapes remain diagnostics. Native no-op tokens stay in raw.
    """
    decoded, evidence, unsupported = {"axes": {}}, {}, []
    axis = "x"  # 0x1310D67 initializes the selector to zero.
    for node in fields:
        tag, values = node["tag"], node.get("values", [])
        if tag in AXES:
            axis = AXES[tag]
            if values:
                unsupported.append({"tag": tag, "offset": node.get("offset"), "reason": "axis marker has values"})
            continue
        if tag == "[object]":
            # 0x1311C42 clears the vector; 0x1311C63..CF8 appends each path/int.
            entries = []
            valid = len(values) % 2 == 0
            for i in range(0, len(values)-1, 2):
                if not isinstance(values[i], str) or type(values[i+1]) is not int:
                    valid = False
                    continue
                # Defer resolution: [object type] may follow [object]. The native
                # reader copies the string verbatim; the generator dispatches it.
                entries.append({"path": values[i], "parameter": values[i+1]})
            decoded["object_entries"] = entries
            evidence["object_entries"] = "E-PARSE"
            if not valid:
                unsupported.append({"tag": tag, "offset": node.get("offset"), "reason": "expected ordered path/int pairs; inspect raw"})
            continue
        spec = AXIS_FIELDS.get(tag) or GLOBAL_FIELDS.get(tag)
        if spec is None:
            unsupported.append({"tag": tag, "offset": node.get("offset"), "reason": "no particle decoder"})
            continue
        key, arity, types = spec
        if len(values) != arity or any(not isinstance(v, types) or isinstance(v, bool) for v in values):
            unsupported.append({"tag": tag, "offset": node.get("offset"), "reason": "unexpected particle field shape; inspect raw"})
            continue
        value = values[0] if arity == 1 else deepcopy(values)
        if tag == "[move type]" and value not in MOVE_TYPES:
            # 0x131185F continues parsing without touching the selected axis
            # if all four string comparisons fail. The token stays in raw.
            continue
        if tag in AXIS_FIELDS:
            decoded["axes"].setdefault(axis, {})[key] = value
            evidence["axes/"+axis+"/"+key] = "E-PARSE"
        else:
            decoded[key] = value
            evidence[key] = "E-PARSE"
    for entry in decoded.get("object_entries", []):
        name = entry["path"]
        if not name:
            # 0xE4E5F9..620 constructs an empty animation object. Resolving an
            # empty name to the PTL directory changes that branch's meaning.
            continue
        object_type = decoded.get("object_type")
        if object_type == "[passive object]" or (object_type == "[animation]" and entry["parameter"] != -1):
            # 0xE4E73A..74A passes the name + integer directly to the image
            # manager, without the PTL folder; passive objects use the integer
            # at 0xE4E47E..484. Keep their names out of script path resolution.
            entry["path"] = name.replace("\\", "/").lower()
        else:
            # 0xE4E67A..6CB loads an ANI with the template folder + its name.
            entry["path"] = resolve(path, name)
    return decoded, evidence, unsupported
