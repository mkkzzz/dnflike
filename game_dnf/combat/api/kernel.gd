extends RefCounted
## Public kernel entry for the transitional battle scene (doc 29). Other modules reach the
## combat internals only through combat/api/ (enforced by tools/check_dnf_deps.py).
const Timeline = preload("res://combat/action/timeline.gd")
const HitJudge = preload("res://combat/hit/hit_judge.gd")
const Reaction = preload("res://combat/resolve/reaction.gd")
const MonsterAI = preload("res://combat/ai/monster_ai.gd")
const MoveTable = preload("res://combat/data/move_table.gd")
