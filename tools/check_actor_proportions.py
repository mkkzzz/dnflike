#!/usr/bin/env python3
"""Fail-closed, reference-bound actor head-scale checks before pose export.

Landmarks are explicit visual annotations, never inferred from the narrowest
silhouette row or from a crouched pose's bounding-box height. Numerical approval
does not approve identity, anatomy, gait, perspective or the artwork itself.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parents[1]


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def resolve(base, value):
    return (Path(base) / value).resolve()


def visible_points(alpha, mark):
    for point in (mark['hair_top'], mark['chin']):
        x, y = (round(value) for value in point)
        if alpha.crop((max(0,x-3), max(0,y-3), min(alpha.width,x+4), min(alpha.height,y+4))).getextrema()[1] < 128:
            return False
    return True


def span(mark, image_size=None):
    """Visible hair-tip-to-chin vertical envelope, not anatomical head count."""
    top, chin = mark['hair_top'], mark['chin']
    if any(len(point) != 2 or any(isinstance(n, bool) or not isinstance(n, (int, float))
           or not math.isfinite(n) for n in point) for point in (top, chin)):
        raise ValueError('head landmarks require two finite [x,y] points')
    if image_size and any(not (0 <= point[0] < image_size[0] and 0 <= point[1] < image_size[1])
                          for point in (top, chin)):
        raise ValueError('head landmark outside source image')
    height = chin[1] - top[1]
    if height <= 0:
        raise ValueError('chin must be below hair top for this upright-head projection')
    if mark.get('projection') != 'upright_head':
        raise ValueError('occluded/strongly tilted head needs a separately reviewed projection profile')
    return height


def assess(config_path, audit_path, repo=REPO):
    repo, config_path, audit_path = Path(repo).resolve(), Path(config_path).resolve(), Path(audit_path).resolve()
    config, audit = read_json(config_path), read_json(audit_path)
    failures = []
    if resolve(repo, audit['config']) != config_path:
        failures.append('audit_config_path_mismatch')
    profile_path = resolve(repo, audit['profile'])
    profile = read_json(profile_path)
    if digest(profile_path) != audit.get('profile_sha256'):
        failures.append('profile_hash_mismatch')
    ratios = []
    for ref in profile['references']:
        path = resolve(repo, ref['file'])
        if digest(path) != ref['sha256']:
            failures.append('reference_hash_mismatch:' + ref['id'])
        with Image.open(path) as image:
            head = span(ref['head'], image.size)
        height = ref['standing_bottom_y'] - ref['standing_top_y']
        if height <= 0 or not (0 <= ref['standing_top_y'] < ref['standing_bottom_y'] <= image.height):
            raise ValueError('invalid standing reference height')
        ratios.append(head / height)
    expected = statistics.median(ratios)
    tolerance = profile['max_head_scale_error_fraction']
    if not (0 < tolerance <= .1):
        raise ValueError('profile tolerance must be positive and no more than 10 percent')
    target = config['target_standing_height']
    if isinstance(target, bool) or not isinstance(target, (int, float)) or not math.isfinite(target) or target <= 0:
        raise ValueError('target_standing_height must be finite and positive')
    if target < profile['min_new_target_standing_height']:
        failures.append('below_new_native_actor_height')
    required = {(pose['source'], pose['id']) for clip in config['clips'].values() for pose in clip['poses']}
    pose_boxes = {(pose['source'], pose['id']): pose['crop_bbox']
                  for clip in config['clips'].values() for pose in clip['poses']}
    annotations = {(entry['source'], entry['pose_id']): entry for entry in audit['poses']}
    if len(annotations) != len(audit['poses']):
        failures.append('duplicate_pose_annotations')
    missing = sorted(required - set(annotations))
    if missing:
        failures.append('missing_pose_annotations')
    unknown = sorted(set(annotations) - required)
    if unknown:
        failures.append('unknown_pose_annotations')
    sources, neutral_checks = {}, []
    for name, source in config['sources'].items():
        path = resolve(config_path.parent, source['file'])
        record = audit['sources'].get(name)
        if not record:
            failures.append('missing_source_binding:' + name)
            continue
        if digest(path) != record.get('sha256'):
            failures.append('source_hash_mismatch:' + name)
        with Image.open(path) as image:
            size = image.size
            alpha = image.convert('RGBA').getchannel('A')
        if alpha.getextrema()[0] == 255:
            failures.append('opaque_action_source:' + name)
        equivalent = source['standing_height']
        basis = record.get('scale_basis', {})
        trusted = False
        if basis.get('kind') == 'same_sheet_neutral_companion':
            neutral_height = basis['standing_bottom_y'] - basis['standing_top_y']
            if neutral_height <= 0:
                raise ValueError('invalid neutral companion height')
            neutral_head = span(basis['head'], size)
            if not visible_points(alpha, basis['head']):
                failures.append('neutral_head_landmark_not_visible:' + name)
            neutral_ratio_error = neutral_head / neutral_height / expected - 1
            height_error = equivalent / neutral_height - 1
            if abs(height_error) > profile['max_neutral_height_error_fraction']:
                failures.append('standing_height_disagrees_with_neutral:' + name)
            if abs(neutral_ratio_error) > tolerance:
                failures.append('neutral_head_ratio_out_of_range:' + name)
            if not (0 <= basis['standing_top_y'] < basis['standing_bottom_y'] <= size[1]):
                failures.append('neutral_bounds_outside_image:' + name)
            sole = basis['sole']
            box = basis['crop_bbox']
            if len(sole) != 2 or any(not isinstance(n,(int,float)) or not math.isfinite(n) for n in sole):
                raise ValueError('neutral sole requires finite [x,y]')
            if not (0 <= sole[0] < size[0] and 0 <= sole[1] < size[1]):
                failures.append('neutral_sole_outside_image:' + name)
            elif not visible_points(alpha, {'hair_top':sole, 'chin':sole}):
                failures.append('neutral_sole_not_visible:' + name)
            if abs(basis['head']['hair_top'][1] - basis['standing_top_y']) > 2 or abs(sole[1] - basis['standing_bottom_y']) > 2:
                failures.append('neutral_height_not_bound_to_hair_and_sole:' + name)
            if len(box) != 4 or not (0 <= box[0] < box[2] <= size[0] and 0 <= box[1] < box[3] <= size[1]):
                raise ValueError('invalid neutral crop_bbox')
            if any(not (box[0] <= point[0] < box[2] and box[1] <= point[1] < box[3])
                   for point in [basis['head']['hair_top'], basis['head']['chin'], sole]):
                failures.append('neutral_landmarks_outside_neutral_crop:' + name)
            equivalent = neutral_height
            trusted = True
            neutral_checks.append({'source': name, 'neutral_height': neutral_height,
                                   'head_ratio_error': neutral_ratio_error,
                                   'configured_height_error': height_error})
        else:
            # Preserve observations of old guessed scales, but never pass them.
            failures.append('unverified_standing_height:' + name)
        if not isinstance(equivalent, (int, float)) or not math.isfinite(equivalent) or equivalent <= 0:
            raise ValueError('standing equivalent must be finite and positive')
        if target / equivalent > 1:
            failures.append('upscale_forbidden:' + name)
        sources[name] = (equivalent, trusted, size, alpha)
    rows = []
    for key, entry in annotations.items():
        name, pose_id = key
        if name not in sources:
            continue
        equivalent, trusted, size, alpha = sources[name]
        head = span(entry['head'], size)
        if not visible_points(alpha, entry['head']):
            failures.append('head_landmark_not_visible:' + pose_id)
        if key in pose_boxes:
            x0, y0, x1, y1 = pose_boxes[key]
            if any(not (x0 <= point[0] < x1 and y0 <= point[1] < y1)
                   for point in (entry['head']['hair_top'], entry['head']['chin'])):
                failures.append('head_landmark_outside_pose_crop:' + pose_id)
        uncertainty = entry['uncertainty_px']
        if not isinstance(uncertainty, (int, float)) or not math.isfinite(uncertainty) or uncertainty < 0 or uncertainty > head * .15:
            raise ValueError('head landmark uncertainty must be explicit, bounded and nonnegative')
        error = head / equivalent / expected - 1
        low = max(0, head - uncertainty) / equivalent / expected - 1
        high = (head + uncertainty) / equivalent / expected - 1
        if abs(error) > tolerance:
            failures.append('head_scale_out_of_range:' + pose_id)
        rows.append({'source': name, 'pose_id': pose_id, 'head_source_px': head,
                     'head_landmarks': entry['head'],
                     'source_standing_height': equivalent, 'scale_basis_verified': trusted,
                     'head_output_px': head * target / equivalent,
                     'reference_head_output_px': expected * target,
                     'relative_error': error, 'landmark_only_error_interval': [low, high],
                     'caveat': 'Legacy standing-height uncertainty is NOT included in this interval.' if not trusted else None})
    return {'schema': 'actor_proportions/1', 'passed': not failures,
            'config': config_path.relative_to(repo).as_posix(), 'audit': audit_path.relative_to(repo).as_posix(),
            'profile': audit['profile'], 'profile_sha256': digest(profile_path),
            'reference_visible_head_ratio': expected, 'tolerance_fraction': tolerance,
            'target_standing_height': target,
            'measured_unique_poses': len(rows), 'required_unique_poses': len(required),
            'missing_pose_annotations': missing, 'unknown_pose_annotations': unknown,
            'neutral_checks': neutral_checks, 'measurements': rows,
            'failures': failures, 'artwork_approved': False,
            'interpretation': 'Visible head scale at the configured standing-equivalent scale; not crouched height divided by head height, and not a traditional anatomical head-count measurement.'}


def preflight(config_path, config, repo=REPO):
    value = config.get('proportion_check')
    if not value:
        raise ValueError('Missing mandatory proportion_check. New exports require a reference-bound neutral companion and head landmarks for EVERY unique pose.')
    audit_path = resolve(Path(config_path).parent, value)
    report = assess(config_path, audit_path, repo)
    if not report['passed']:
        raise ValueError('Actor proportion gate FAILED: ' + ', '.join(report['failures']))
    return report


def legacy_rebuild(config_path, repo=REPO):
    repo, config_path = Path(repo).resolve(), Path(config_path).resolve()
    allowlist = repo / 'art/animations/players/swordsman/v7/reviews/2026-10-17_proportions/legacy_rebuild_allowlist.json'
    record = read_json(allowlist)['configs'].get(config_path.relative_to(repo).as_posix())
    if not record or record['sha256'] != digest(config_path):
        raise ValueError('--legacy-rebuild is only for the exact archived config paths AND hashes, never a new or modified candidate')
    return {'passed': False, 'status': 'historical_rebuild_only_proportion_gate_not_passed',
            'integration_allowed': False, 'config_sha256': digest(config_path)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('audit', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    audit = read_json(args.audit)
    report = assess(resolve(REPO, audit['config']), args.audit)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
    print(json.dumps(report, ensure_ascii=False, indent=2))
    raise SystemExit(0 if report['passed'] else 2)


if __name__ == '__main__':
    main()
