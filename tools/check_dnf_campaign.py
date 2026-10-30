"""Require every source task in the curated level 1-16 campaign to execute."""
from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
RULES = ROOT / 'game_dnf/data/native_quest_rules_v2.json'


def main() -> int:
    runtime = json.loads(RULES.read_text(encoding='utf-8'))
    campaign = runtime.get('campaign') or {}
    if campaign.get('id') != 'campaign_1_16':
        print('[CAMPAIGN] FAIL missing campaign summary; rebuild quest rules')
        return 1
    print('[CAMPAIGN] %s %d / %d executable, target Lv.%s'
          % (campaign.get('id'), campaign.get('executable', 0), campaign.get('required', 0),
             campaign.get('target_level', '?')))
    missing = [row for row in campaign.get('rows', []) if row.get('state') == 'blocked']
    if missing:
        print('[CAMPAIGN] FAIL missing %d' % len(missing))
        for row in missing:
            print('  - %s: %s' % (row.get('source_id'), ', '.join(row.get('reasons', []))))
        return 1
    print('[CAMPAIGN] OK required source chain is executable')
    return 0


if __name__ == '__main__':
    sys.exit(main())
