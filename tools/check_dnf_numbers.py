"""Validate the configurable numeric baseline before launching game_dnf.

This validates executable contracts, not original DNF balance or gameplay pacing.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT = ROOT / 'game_dnf/data/numbers.json'


def validate(data: dict) -> list[str]:
    errors: list[str] = []

    def require(condition: bool, message: str) -> None:
        if not condition:
            errors.append(message)

    def number(value, low=None, high=None, integer=False) -> bool:
        return (isinstance(value, (int, float)) and not isinstance(value, bool)
                and math.isfinite(value) and (low is None or value >= low)
                and (high is None or value <= high) and (not integer or int(value) == value))

    if not isinstance(data, dict):
        return ['root must be an object']
    require(data.get('schema') == 'dnf_numbers/1', 'unsupported schema')
    for key in ['progression', 'formula', 'base', 'growth', 'growtypes', 'limits', 'equipment', 'skills', 'skill_defaults', 'effects', 'monsters']:
        require(isinstance(data.get(key), dict), f'{key} must be an object')
    if errors:
        return errors
    p, f, base = data['progression'], data['formula'], data['base']
    required_stats = {'hp_max', 'mp_max', 'strength', 'intelligence', 'vitality', 'spirit',
                      'physical_attack', 'magical_attack', 'independent_attack',
                      'physical_defense', 'magical_defense', 'hit', 'evasion',
                      'physical_crit', 'magical_crit', 'attack_speed', 'move_speed',
                      'cast_speed', 'cooldown_rate', 'mp_cost_rate', 'damage_rate',
                      'taken_rate', 'skill_rate', 'hp_regen', 'mp_regen',
                      'hit_recovery', 'jump_power', 'status_resist'}
    required_stats.update(f'{element}_{suffix}' for element in ['fire', 'water', 'light', 'dark'] for suffix in ['attack', 'resist'])
    require(required_stats <= base.keys(), 'base is missing required combat attributes')
    require(number(data.get('revision'), 1, integer=True), 'revision must be a positive integer')
    require(number(p.get('level_cap'), 1, 1000, True), 'level_cap must be 1..1000')
    require(isinstance(p.get('xp_per_level'), list) and all(number(x, 1, 10**9, True) for x in p['xp_per_level']), 'xp_per_level must contain positive integers')
    for key in ['xp_fallback_per_level', 'sp_initial', 'sp_per_level', 'clear_xp', 'kill_xp']:
        require(number(p.get(key), 1 if key == 'xp_fallback_per_level' else 0, 10**9, True), f'progression.{key} is invalid')
    require(p.get('level_up_vitals') in ['preserve', 'refill'], 'level_up_vitals must be preserve or refill')
    require(isinstance(p.get('enforce_skill_requirements'), bool), 'enforce_skill_requirements must be boolean')
    for key in ['main_stat_divisor', 'vitality_divisor', 'spirit_divisor', 'defense_base', 'element_divisor']:
        require(number(f.get(key), 0.000001), f'formula.{key} must be positive')
    for key in ['defense_per_attacker_level', 'element_min', 'critical_multiplier', 'minimum_damage', 'hit_base', 'hit_min', 'hit_max', 'counter_multiplier', 'back_multiplier', 'reinforce_attack_per_level', 'quality_min_scale', 'quality_max_scale']:
        require(number(f.get(key), 0), f'formula.{key} must be non-negative')
    require(f.get('hit_min', 0) <= f.get('hit_max', 1) <= 1, 'hit range must be ordered and <= 1')
    require(f.get('quality_min_scale', 0) <= f.get('quality_max_scale', 1), 'quality scale must be ordered')
    for key, value in base.items():
        require(number(value), f'base.{key} must be finite')
    for key, value in data['growth'].items():
        require(key in base and number(value), f'growth.{key} must refer to a numeric base stat')
    for growtype, values in data['growtypes'].items():
        require(isinstance(values, dict) and all(k in base and number(v) for k, v in values.items()), f'growtypes.{growtype} is invalid')
    require('swordman' in data['growtypes'], 'default swordman growtype missing')
    for key, bounds in data['limits'].items():
        require(key in base and isinstance(bounds, list) and len(bounds) == 2 and all(number(v) for v in bounds) and bounds[0] <= bounds[1], f'limits.{key} is invalid')

    def modifier(mod, where):
        require(isinstance(mod, dict) and mod.get('stat') in base and mod.get('op', 'add') in ['add', 'percent', 'mul'] and number(mod.get('value')), f'{where}: invalid modifier')

    slots = data.get('equipment_slots', [])
    require(isinstance(slots, list) and 'weapon' in slots and len(slots) == len(set(slots)), 'equipment_slots must be unique and include weapon')
    for key, gear in data['equipment'].items():
        require(isinstance(gear, dict), f'equipment.{key} must be an object')
        if not isinstance(gear, dict):
            continue
        require(gear.get('slot') in slots and number(gear.get('required_level', 1), 1, integer=True), f'equipment.{key}: invalid slot or requirement')
        require(isinstance(gear.get('stats'), dict) and all(k in base and number(v) for k, v in gear['stats'].items()), f'equipment.{key}: invalid stats')
        require(gear.get('element', 'none') in ['none', 'fire', 'water', 'light', 'dark'], f'equipment.{key}: invalid element')
    for key, skill in data['skills'].items():
        require(isinstance(skill, dict), f'skills.{key} must be an object')
        if not isinstance(skill, dict):
            continue
        require(number(skill.get('max_level'), 1, 1000, True) and number(skill.get('cost', 0), 0, 10**6, True), f'skills.{key}: invalid rank or cost')
        require(number(data['skill_defaults'].get(key), 0, skill.get('max_level', 0), True), f'skill_defaults.{key}: invalid rank')
        for mod in skill.get('passive', []):
            modifier(mod, f'skills.{key}.passive')
        for parent, rank in skill.get('requires', {}).items():
            require(parent in data['skills'] and number(rank, 1, integer=True), f'skills.{key}: invalid prerequisite')
        for effect in skill.get('on_hit', []):
            require(isinstance(effect, dict) and effect.get('id') in data['effects'] and number(effect.get('chance', 1), 0, 1), f'skills.{key}: invalid on-hit effect')
    for key, effect in data['effects'].items():
        require(isinstance(effect, dict), f'effects.{key} must be an object')
        if not isinstance(effect, dict):
            continue
        require(number(effect.get('duration_ms'), 1) and effect.get('stacking', 'refresh') in ['refresh', 'stack'] and number(effect.get('max_stacks', 1), 1, 100, True), f'effects.{key}: invalid lifecycle')
        require(number(effect.get('interval_ms', 0), 0) and number(effect.get('tick_damage', 0), 0), f'effects.{key}: invalid periodic tick')
        for mod in effect.get('modifiers', []):
            modifier(mod, f'effects.{key}')
    for key, tiers in data.get('sets', {}).items():
        for tier in tiers:
            require(number(tier.get('count'), 1, len(slots), True), f'sets.{key}: invalid threshold')
            for mod in tier.get('modifiers', []):
                modifier(mod, f'sets.{key}')
    for key in ['hp_per_level', 'attack_per_level', 'defense_per_level']:
        require(number(data['monsters'].get(key), 0), f'monsters.{key} must be non-negative')
    require(isinstance(data['monsters'].get('difficulty'), dict) and 'normal' in data['monsters']['difficulty'] and all(number(v, 0.000001) for v in data['monsters']['difficulty'].values()), 'monster difficulty factors must be positive')
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=DEFAULT)
    args = parser.parse_args()
    try:
        errors = validate(json.loads(args.config.read_text(encoding='utf-8')))
    except (OSError, ValueError, TypeError, KeyError) as exc:
        errors = [str(exc)]
    for error in errors:
        print('[DNF_NUMBERS] FAIL ' + error)
    print(f'[DNF_NUMBERS] {"FAILED" if errors else "OK"} errors={len(errors)}')
    return int(bool(errors))


if __name__ == '__main__':
    raise SystemExit(main())
