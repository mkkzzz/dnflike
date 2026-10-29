"""Validate recovery items, simulation cooldowns and the adapted revival economy."""
import json
from pathlib import Path
import sys
from check_dnf_services import load

ROOT = Path(__file__).resolve().parents[1]


def validate(cfg, catalog):
    errors = []

    def whole(value, low, high):
        return type(value) is int and low <= value <= high

    if not isinstance(cfg, dict) or cfg.get('revision') != 1:
        return ['unsupported recovery config']
    items = cfg.get('consumables')
    if not isinstance(items, dict) or not items:
        errors.append('missing consumables')
    else:
        for item, rule in items.items():
            if catalog.get(item) != 'consumable' or not isinstance(rule, dict):
                errors.append('invalid consumable ' + item)
                continue
            if not whole(rule.get('level'), 1, 60):
                errors.append('invalid item level ' + item)
            for field in ['cooldown_ms', 'group_cooldown_ms']:
                if not whole(rule.get(field), 0, 3600000):
                    errors.append('invalid cooldown ' + item)
            if not isinstance(rule.get('group'), str) or not 1 <= len(rule['group']) <= 64:
                errors.append('invalid cooldown group ' + item)
            effect = rule.get('effect')
            valid_effect=isinstance(effect,dict) and effect.get('kind')=='heal' and whole(effect.get('amount'),1,1000000)
            if isinstance(effect,dict) and effect.get('kind')=='restore':
                valid_effect=all(whole(effect.get(k),0,1000000) for k in ['hp','mp']) and effect['hp']+effect['mp']>0 and whole(effect.get('duration_ms'),0,600000)
            if not valid_effect:
                errors.append('invalid healing effect ' + item)
    revival = cfg.get('revival')
    if not isinstance(revival, dict):
        errors.append('missing revival')
    else:
        for field, low, high in [('limit', 0, 100), ('gold', 0, 1000000), ('gold_increment', 0, 1000000),
                                 ('hp_percent', 1, 100), ('mp_percent', 0, 100), ('invulnerable_ms', 0, 30000)]:
            if not whole(revival.get(field), low, high):
                errors.append('invalid revival ' + field)
    return errors


def inputs():
    _, catalog, _ = load()
    return json.loads((ROOT / 'game_dnf/data/recovery.json').read_text(encoding='utf8')), catalog


if __name__ == '__main__':
    errors = validate(*inputs())
    for error in errors:
        print('[DNF_RECOVERY] FAIL ' + error)
    print('[DNF_RECOVERY] ' + ('OK' if not errors else 'FAILED') + ' errors=' + str(len(errors)))
    sys.exit(bool(errors))
