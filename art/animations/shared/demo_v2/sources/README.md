# Combat demo character art v2

Generated with the built-in `image_gen.imagegen` tool on 2026-10-14. The exact
prompts and original character references are recorded in
`demo_v2_generation.json`. Character originals now live under
`art/concepts/characters/`; their image contents are unchanged.

## Source atlases

- `player_demo_v2.png`: actual transparent RGBA, 1254 x 1254, 4 x 4 logical grid.
- `monster_demo_v2.png`: actual transparent RGBA, 1254 x 1254, 4 x 4 logical grid.

Each atlas contains sixteen genuinely different character key poses. Rows are
ready/defense, four stride phases, four attack poses, and reaction/recovery.
The hero has silver hair with a red streak, a black coat with red lining, and a
black-handled sword. The goblin retains the original green skin, yellow eyes,
leather equipment and spiked wooden club.

## Reproduce

```powershell
python tools/bake_demo_art.py
python tools/bake_demo_art.py --validate-only
```

Pillow and NumPy are required. Outputs are committed under
`game/assets/demo/player/`, `game/assets/demo/monster/`, and
`game/assets/demo/anim.json`. Source-space annotations and action-to-pose
mapping live in `tools/bake_demo_art.py`; a machine-readable geometry report
is written to `demo_v2_bake_report.json`.

The baker associates sixteen connected characters with the regular atlas
grid. Full connected weapons remain assigned to their character even where
the generated atlas lets a tip cross a cell boundary. It preserves source
alpha and applies one fixed scale to each entire character: player standing
body height 190 px, goblin body height 132 px. Reviewed source floor/root
annotations prevent a horizontal sword from shifting the character anchor.
No per-frame or per-action size normalization is used.

All player actions share a 296 x 238 canvas and foot anchor (128, 221).
All goblin actions share a 239 x 222 canvas and foot anchor (114, 201).
Every baked frame has transparent padding around its silhouette. The review
boards mark the shared floor in red and the origin in yellow.

## Animation scope

This is a limited-keyframe demo art set, not a fully in-betweened production
animation library. There are 32 unique original poses and 83 output frames
across 25 action strips. Source cell numbers are zero-based. Every manifest
entry includes `source_cells` and `pose_note` so reuse is explicit.

The hero's four stride poses, windup, horizontal slash, rising cut, heavy cut,
crouch, airborne, guard, recoil, grounded knockdown, and kneeling getup all use
real matching drawings. Three basic attacks use different cut poses. Idle
uses two different ready poses. Guard and airborne states hold one matching
key pose while game physics supplies movement. Back hop reuses crouch and
airborne poses. Blood rage reuses guard/windup with runtime aura effects.
Rage slash and quick draw combine core attack poses with runtime effects.
Thrust currently repeats the horizontal extension pose three times; a
dedicated stabbing sequence remains an art follow-up.

The goblin uses four actual stride poses, four club attack poses, recoil,
airborne knockback, knockdown and getup poses. Patrol and chase share the
stride drawing set at different playback speeds.

## Review files

- `player_demo_v2_review.png`, `monster_demo_v2_review.png`: every unique pose
  at the exact runtime scale and shared anchor.
- `player_run_demo_v2.gif`, `player_attack3_demo_v2.gif`,
  `player_rage_slash_demo_v2.gif`: core hero motion previews.
- `monster_chase_demo_v2.gif`, `monster_attack_demo_v2.gif`: goblin motion
  previews.

The baker validates all 83 strip frames, duration counts, transparent padding,
nonempty silhouettes, and shared geometry within each character.
