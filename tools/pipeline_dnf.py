"""原版内容接入流水线：把"新副本 / 新怪物 / 新场景"从原版数据一路做到可玩、可校验。

为什么要有它：接入一条内容要按依赖顺序跑 6~8 个工具，顺序错了（例如先烘图集后编内容包）
就会出现"图集有了但运行时查不到怪"这类静默失败。这里把顺序和幂等固化下来。

子命令：
  dungeon <dgn 路径> --id <id> --name <中文名> [--region R] [--level N]
      导出地图 → 生成路线入表 → 重编内容包 → 重建战斗资源 → 同步怪物映射 → 补 BGM → 校验
  monsters
      只做怪物侧：总账 → 动作图集 → 内容包 → 战斗资源 → 映射 → 校验（副本引用变化后跑）
  verify
      只跑全部检查（提交前用）

用法示例：
  python tools/pipeline_dnf.py dungeon dungeon/act1/grakkarak.dgn --id grakkarak --name 格拉卡
  python tools/pipeline_dnf.py monsters
  python tools/pipeline_dnf.py verify
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / 'tools'
GAME = ROOT / 'game_dnf'


def run(label: str, args: list[str], required: bool = True) -> bool:
    """跑一个工具；required=False 时失败只提示不中断（用于可选步骤）。"""
    started = time.time()
    print('[PIPE] %-34s ...' % label, end='', flush=True)
    done = subprocess.run([sys.executable, *args], cwd=str(ROOT), capture_output=True, text=True)
    cost = time.time() - started
    if done.returncode != 0:
        print(' FAIL %.0fs' % cost)
        tail = ((done.stdout or '') + (done.stderr or '')).strip().splitlines()[-6:]
        for line in tail:
            print('       ' + line[:160])
        if required:
            raise SystemExit('[PIPE] 中断：%s 失败' % label)
        return False
    print(' ok %.0fs' % cost)
    return True


def tool(name: str) -> str:
    return str(TOOLS / name)


def verify() -> int:
    """全部检查；任一失败即非零退出。"""
    checks = [
        ('副本契约', [tool('check_dnf_dungeons.py')]),
        ('BGM 覆盖', [tool('check_dnf_bgm.py')]),
        ('走区一致', [tool('check_dnf_walk.py')]),
        ('任务进度', [tool('check_dnf_quests.py')]),
    ]
    failed = []
    for label, args in checks:
        done = subprocess.run([sys.executable, *args], cwd=str(ROOT), capture_output=True, text=True)
        status = 'ok' if done.returncode == 0 else 'FAIL'
        print('[VERIFY] %-10s %s' % (label, status))
        if done.returncode != 0:
            failed.append(label)
            for line in ((done.stdout or '') + (done.stderr or '')).strip().splitlines()[-8:]:
                print('         ' + line[:160])
    if failed:
        print('[VERIFY] 失败：%s' % '、'.join(failed))
        return 1
    print('[VERIFY] 全部通过')
    return 0


def monster_side(with_content: bool = True) -> None:
    """怪物侧全链路：总账 → 内容包 → 图集 → 映射。顺序不能反。"""
    run('怪物总账 (.mob 解析)', [tool('build_dnf_monster_catalog.py')])
    if with_content:
        # 内容包必须在图集之前：图集烘焙依赖 catalog，运行时则依赖内容包里的 mob 记录。
        run('内容包 (mob/ani/atk)', [tool('compile_dnf_content.py')])
    run('战斗图集 (按动动作烘焙)', [tool('build_dnf_combat_assets.py')])
    run('怪物映射 (mob→kind)', [tool('sync_dnf_monster_mapping.py')])


def dungeon_side(dgn: str, dungeon_id: str, name: str, region: str, level: int) -> None:
    output = GAME / 'assets_local/flow_v1' / ('skytower_v1' if region == 'skytower' else 'gran_v1') / dungeon_id
    run('导出地图 %s' % dungeon_id, [tool('export_dnf_map.py'), '--dungeon', dgn, '--output', str(output)])
    # --export 要的是 map_export.json 这个文件，不是导出目录。
    export_file = output / 'map_export.json'
    run('生成路线入表', [tool('build_dnf_dungeon_route.py'), '--write', '--id', dungeon_id, '--name', name,
                         '--export', 'res://' + str(export_file.relative_to(GAME)).replace('\\', '/'),
                        '--region', region, '--monster-level', str(level)])
    # 新副本的怪可能没进过内容包/图集，必须重走怪物侧
    monster_side(with_content=True)
    run('BGM 映射', [tool('bake_dnf_bgm.py')], required=False)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest='command', required=True)

    dungeon = sub.add_parser('dungeon', help='接入一个新副本（全链路）')
    dungeon.add_argument('dgn')
    dungeon.add_argument('--id', required=True)
    dungeon.add_argument('--name', required=True)
    dungeon.add_argument('--region', default='granfloris')
    dungeon.add_argument('--level', type=int, default=10)

    sub.add_parser('monsters', help='怪物侧全链路（副本引用变化后跑）')
    sub.add_parser('verify', help='只跑全部检查')

    args = parser.parse_args()
    if args.command == 'verify':
        return verify()
    if args.command == 'monsters':
        monster_side()
        return verify()
    dungeon_side(args.dgn, args.id, args.name, args.region, args.level)
    return verify()


if __name__ == '__main__':
    raise SystemExit(main())
