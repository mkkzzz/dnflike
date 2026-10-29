"""Validate configurable town economy contracts, not original DNF prices."""
import json
from pathlib import Path
import re
import sys
ROOT=Path(__file__).resolve().parents[1]

def validate(cfg, catalog, gear):
    errors=[]
    def whole(value,lo,hi):return type(value) is int and lo<=value<=hi
    if not isinstance(cfg,dict) or cfg.get('revision')!=1:return ['unsupported service config']
    for key,lo,hi in [('buyback_limit',1,1000),('durability_max',1,100000)]:
        if not whole(cfg.get(key),lo,hi):errors.append('invalid '+key)
    wear=cfg.get('wear',{})
    if not isinstance(wear,dict):errors.append('invalid wear');wear={}
    for key,lo in [('weapon_hits',1),('armor_hits',1),('death_loss',0)]:
        if not whole(wear.get(key),lo,1000000):errors.append('invalid wear/'+key)
    items=cfg.get('items')
    if not isinstance(items,dict):return errors+['missing items']
    if set(items)!=set(catalog):errors.append('all catalog items must have exactly one service rule')
    for key,entry in items.items():
        if not isinstance(entry,dict):errors.append('invalid rule '+key);continue
        if not whole(entry.get('sell'),0,1000000):errors.append('invalid sell '+key)
        if key in gear:
            if not whole(entry.get('repair_point'),1,1000000):errors.append('invalid repair '+key)
            output=entry.get('disassemble')
            if not isinstance(output,dict) or not output:errors.append('missing disassembly '+key);continue
            for item,amount in output.items():
                if catalog.get(item)!='material' or not whole(amount,1,100000):errors.append('invalid disassembly output '+key)
    return errors

def load():
    source=(ROOT/'game_dnf/items/catalog.gd').read_text(encoding='utf8')
    catalog=dict(re.findall(r'^\s*"([^"]+)":\s*\{[^\n]*?"kind":\s*"([^"]+)"',source,re.M))
    compiled=json.loads((ROOT/'game_dnf/data/runtime_items.json').read_text(encoding='utf8'))
    catalog.update({key:value['kind'] for key,value in compiled['items'].items()})
    cfg=json.loads((ROOT/'game_dnf/data/services.json').read_text(encoding='utf8'))
    gear=json.loads((ROOT/'game_dnf/data/numbers.json').read_text(encoding='utf8'))['equipment']
    return cfg,catalog,gear

if __name__=='__main__':
    errors=validate(*load())
    for error in errors:print('[DNF_SERVICES] FAIL '+error)
    print('[DNF_SERVICES] '+('OK' if not errors else 'FAILED')+' errors='+str(len(errors)))
    sys.exit(1 if errors else 0)
