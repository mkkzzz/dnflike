"""Validate configurable upgrade bills, outcomes, slots and numeric modifiers."""
import json
from pathlib import Path
import sys
from check_dnf_services import load

ROOT = Path(__file__).resolve().parents[1]


def validate(cfg, catalog, numbers):
    errors = []

    def whole(value, low, high):
        return type(value) is int and low <= value <= high

    def bill(entry, label):
        if not isinstance(entry, dict):
            errors.append('invalid bill ' + label)
            return
        if not whole(entry.get('gold'), 0, 1000000):
            errors.append('invalid gold ' + label)
        materials = entry.get('materials')
        if not isinstance(materials, dict) or not materials:
            errors.append('missing materials ' + label)
            return
        for item, amount in materials.items():
            if catalog.get(item) != 'material' or not whole(amount, 1, 100000):
                errors.append('invalid material ' + label)

    if not isinstance(cfg, dict) or cfg.get('revision') != 1:
        return ['unsupported upgrade config']
    reinforcement = cfg.get('reinforcement')
    if not isinstance(reinforcement, dict):
        return ['missing reinforcement']
    bonuses = reinforcement.get('bonuses')
    if not isinstance(bonuses, dict):
        errors.append('invalid reinforcement bonuses')
    else:
        for slot, stats in bonuses.items():
            if slot not in numbers['equipment_slots'] or slot == 'weapon':
                errors.append('invalid bonus slot ' + slot)
            if not isinstance(stats, dict) or not stats:
                errors.append('missing slot bonuses ' + slot)
                continue
            for stat, value in stats.items():
                if stat not in numbers['base'] or not whole(value, 1, 100000):
                    errors.append('invalid reinforcement stat ' + slot)
    steps = reinforcement.get('steps')
    if not isinstance(steps, list) or not 1 <= len(steps) <= 30:
        errors.append('reinforcement steps must contain 1..30 levels')
    else:
        for index, entry in enumerate(steps):
            bill(entry, str(index + 1))
            if not isinstance(entry, dict):
                continue
            if not whole(entry.get('chance'), 0, 100):
                errors.append('invalid chance ' + str(index + 1))
            if not whole(entry.get('failure_level'), 0, index):
                errors.append('failure cannot upgrade or destroy gear')
    enchants = cfg.get('enchants')
    if not isinstance(enchants, dict) or not enchants:
        errors.append('missing enchant recipes')
    else:
        for key, entry in enchants.items():
            bill(entry, key)
            if not isinstance(entry, dict):
                continue
            if not isinstance(entry.get('name'), str) or not entry['name'].strip():
                errors.append('invalid recipe name ' + key)
            slots = entry.get('slots')
            if not isinstance(slots, list) or not slots or any(slot not in numbers['equipment_slots'] for slot in slots):
                errors.append('invalid enchant slots ' + key)
            mod = entry.get('modifier')
            if not isinstance(mod, dict) or mod.get('stat') not in numbers['base'] or mod.get('op') != 'add' or not whole(mod.get('value'), 1, 100000):
                errors.append('invalid enchant modifier ' + key)
    return errors


def inputs():
    _, catalog, _ = load()
    cfg = json.loads((ROOT / 'game_dnf/data/upgrades.json').read_text(encoding='utf8'))
    numbers = json.loads((ROOT / 'game_dnf/data/numbers.json').read_text(encoding='utf8'))
    return cfg, catalog, numbers


if __name__ == '__main__':
    errors = validate(*inputs())
    for error in errors:
        print('[DNF_UPGRADES] FAIL ' + error)
    print('[DNF_UPGRADES] ' + ('OK' if not errors else 'FAILED') + ' errors=' + str(len(errors)))
    sys.exit(bool(errors))
