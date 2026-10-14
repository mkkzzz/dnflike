"""60 Hz preview simulation: player swing timeline, hit-stop, target reaction and FX."""
from __future__ import annotations

import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

from . import fx as F
from .monster import monster_pose, READY as M_READY, BREATHE, CROUCH, RECOIL, AIRBORNE, DOWN
from .moves import GROUND_Y, HIT_PALETTE, MOVES, PALETTES, READY
from .poses import pose
from .weapon import PROFILE, draw_katana

ROOT = Path(__file__).resolve().parents[2]
BG = ROOT / 'game' / 'assets' / 'demo' / 'bg_dungeon.png'
DT = 1.0 / 60.0


def ease(kind: str, x: float) -> float:
    x = min(1.0, max(0.0, x))
    if kind == 'lin':
        return x
    if kind == 'smooth':
        return x * x * (3 - 2 * x)
    if kind == 'out':
        return 1 - (1 - x) ** 2
    if kind == 'in':
        return x * x
    if kind == 'out3':
        return 1 - (1 - x) ** 3
    if kind == 'in_out_fast':
        return x ** 1.7
    raise ValueError(kind)


def slerp(a: np.ndarray, b: np.ndarray, k: float) -> np.ndarray:
    a, b = a / np.linalg.norm(a), b / np.linalg.norm(b)
    dot = float(np.clip(np.dot(a, b), -1, 1))
    om = math.acos(dot)
    if om < 1e-4:
        return a
    return (math.sin((1 - k) * om) * a + math.sin(k * om) * b) / math.sin(om)


def _premult(img: Image.Image) -> np.ndarray:
    a = np.asarray(img.convert('RGBA')).astype(np.float32) / 255.0
    a[..., :3] *= a[..., 3:4]
    return a


_PM_CACHE: dict = {}


def premult_of(key, img: Image.Image) -> np.ndarray:
    if key not in _PM_CACHE:
        _PM_CACHE[key] = _premult(img)
    return _PM_CACHE[key]


def paste(rgb: np.ndarray, pm: np.ndarray, x: float, y: float, mul=None, add=None) -> None:
    x, y = int(round(x)), int(round(y))
    h, w = pm.shape[:2]
    H, W = rgb.shape[:2]
    x0, y0, x1, y1 = max(0, x), max(0, y), min(W, x + w), min(H, y + h)
    if x1 <= x0 or y1 <= y0:
        return
    src = pm[y0 - y:y1 - y, x0 - x:x1 - x]
    col = src[..., :3]
    a = src[..., 3:4]
    if mul is not None:
        col = col * np.asarray(mul, np.float32)
    if add is not None:
        col = col + a * np.asarray(add, np.float32)
    rgb[y0:y1, x0:x1] = col + rgb[y0:y1, x0:x1] * (1 - a)


# --------------------------------------------------------------------------
# Player
# --------------------------------------------------------------------------

class Player:
    def __init__(self, x: float, schedule: list[tuple[int, str]], scale: float):
        self.x0 = x
        self.schedule = sorted(schedule)
        self.ptime = 0
        self.S = scale
        self.hit_done: set[int] = set()
        self.ground_done: set[int] = set()
        self.edge = np.array([0.0, 1.0, 0.0])
        # During hit-stop the pose, blade and trail hold the exact contact sub-tick.
        self.freeze_t = None
        self.resume_hold = False

    def view_t(self) -> float:
        return self.freeze_t if self.freeze_t is not None else float(self.ptime)

    def current(self, t=None):
        t = self.ptime if t is None else int(math.floor(t))
        cur = None
        for i, (start, name) in enumerate(self.schedule):
            if start <= t:
                cur = (i, start, name)
        if cur is None:
            return None
        i, start, name = cur
        if t - start >= MOVES[name]['length']:
            return None
        return cur

    def root_x(self, t=None) -> float:
        t = self.view_t() if t is None else t
        x = self.x0
        for start, name in self.schedule:
            if start > t:
                break
            m = MOVES[name]
            a, b, dist = m['motion']
            lt = t - start
            x += dist * F.smoothstep(a, b, np.float64(lt)) if lt < m['length'] else dist
        return float(x)

    def pose_key(self, t: float):
        cur = self.current(int(math.floor(t)))
        if cur is None:
            return ('idleback', int(t // 15) % 8)
        _, start, name = cur
        lt = t - start
        key = MOVES[name]['poses'][0]
        for k in MOVES[name]['poses']:
            if k[0] <= lt:
                key = k
        return (key[1], key[2])

    def blade(self, t: float):
        """(direction3, theta|None, motion tangent3|None, move name|None)."""
        cur = self.current(int(math.floor(t)))
        if cur is None:
            return READY, None, None, None
        _, start, name = cur
        m = MOVES[name]
        lt = t - start
        segs = m['blade']
        seg = segs[-1]
        for s in segs:
            if lt <= s[1]:
                seg = s
                break
        t0, t1, kind, a, b, e = seg
        k = ease(e, (lt - t0) / max(1e-6, t1 - t0))
        if kind == 'arc':
            th = a + (b - a) * k
            d = F.plane_dir(m['plane'], th)
            u, v = m['plane']
            r = math.radians(th)
            sign = math.copysign(1.0, b - a) if b != a else m['sweep']
            tan = (-math.sin(r) * u + math.cos(r) * v) * sign
            return d, th, tan, name
        return slerp(np.asarray(a), np.asarray(b), k), None, None, name

    def hand_world(self, t: float):
        sheet, cell = self.pose_key(t)
        p = pose(sheet, cell, self.S)
        return (self.root_x(t) + p.hand[0], GROUND_Y + p.hand[1]), p

    def clamp_ground(self, t, d, th, m):
        """Stop a falling blade on the floor instead of letting it sink below."""
        hand, _ = self.hand_world(t)
        if hand[1] + F.project(d * PROFILE['length'])[1] <= GROUND_Y - 2:
            return d, th
        sweep = m['sweep']
        lo, hi = th - 90 * sweep, th
        for _ in range(18):
            mid = (lo + hi) / 2
            dd = F.plane_dir(m['plane'], mid)
            if hand[1] + F.project(dd * PROFILE['length'])[1] <= GROUND_Y - 2:
                lo = mid
            else:
                hi = mid
        return F.plane_dir(m['plane'], lo), lo

    def blade_points(self, t: float, samples=24, clamp=True):
        hand, _ = self.hand_world(t)
        d, th, tan, name = self.blade(t)
        pts = []
        for x in np.linspace(30, PROFILE['length'], samples):
            q = F.project(d * x)
            pts.append((hand[0] + q[0], hand[1] + q[1]))
        return hand, d, th, tan, name, pts


# --------------------------------------------------------------------------
# Target
# --------------------------------------------------------------------------

class Target:
    def __init__(self, x: float, scale: float):
        self.base_x = x
        self.S = scale
        self.clock = 0
        self.hit_clock = None
        self.hit_real = None
        self.hitstop = 0
        self.heavy = False
        self.knock_from = x
        self.knock_dist = 0.0
        self.knock_t0 = 0
        self.knockdown = False
        self.hop_y = 0.0
        self.hop_v = 0.0
        self.real = 0

    def x(self) -> float:
        if self.hit_clock is None:
            return self.base_x
        k = F.smoothstep(0.0, 1.0, np.float64(min(1.0, (self.clock - self.knock_t0) / 12.0)))
        return float(self.knock_from + self.knock_dist * (1 - (1 - k) ** 2))

    def cell(self) -> int:
        if self.hit_clock is None:
            return M_READY if (self.clock // 25) % 2 == 0 else BREATHE
        c = self.clock - self.hit_clock
        if self.knockdown:
            if c < 4:
                return RECOIL
            if self.hop_y < -1 or c < 14:
                return AIRBORNE
            return DOWN
        if c < 8:
            return RECOIL
        if c < 13:
            return CROUCH
        if c < 17:
            return M_READY
        return M_READY if (self.clock // 25) % 2 == 0 else BREATHE

    def sprite(self):
        return monster_pose(self.cell(), self.S, -1)

    def on_hit(self, hit: dict, real_tick: int, contact=(0.0, 0.0)) -> None:
        cur = self.x()
        self.contact_rel = (contact[0] - cur, contact[1] - GROUND_Y)
        self.hit_clock = self.clock
        self.hit_real = real_tick
        self.hitstop = hit['hitstop']
        self.heavy = hit.get('heavy', False)
        self.knock_from = cur
        self.knock_dist = hit['knock']
        self.knock_t0 = self.clock
        if hit.get('knockdown') or hit.get('iai'):
            self.knockdown = True
            self.hop_v = -330.0 if hit.get('knockdown') else -260.0

    def step(self, frozen: bool) -> None:
        self.real += 1
        if frozen:
            return
        self.clock += 1
        if self.knockdown and self.hit_clock is not None and self.clock - self.hit_clock > 2:
            self.hop_v += 1500.0 * DT
            self.hop_y = min(0.0, self.hop_y + self.hop_v * DT)
            if self.hop_y >= 0 and self.hop_v > 0:
                self.hop_v = 0.0

    def alpha_at(self, wx: float, wy: float) -> float:
        sp = self.sprite()
        pm = premult_of(('m', self.cell()), sp.image)
        px = int((wx - self.x()) * self.S - sp.offset[0])
        py = int((wy - (GROUND_Y + self.hop_y)) * self.S - sp.offset[1])
        if 0 <= py < pm.shape[0] and 0 <= px < pm.shape[1]:
            return float(pm[py, px, 3])
        return 0.0

    def look(self, real_tick: int):
        """(white flash, red tint, shake px, squash k)."""
        if self.hit_real is None:
            return 0.0, 0.0, 0.0, 0.0, 0.0
        h = real_tick - self.hit_real
        hs = self.hitstop
        if h == 0:
            white = 0.26
        elif h == 1:
            white = 0.12
        elif h < hs:
            white = 0.06 if (h // 2) % 2 == 0 else 0.0
        else:
            white = 0.0
        red = 0.42 * max(0.0, 1 - h / 16.0)
        rim = max(0.0, 1 - h / (hs + 6.0)) ** 1.3
        shake = (1.0 if h % 2 == 0 else -1.0) * (3.0 if self.heavy else 2.0) if h < hs else 0.0
        k = 1.0 if h < hs else max(0.0, 1 - (h - hs) / 12.0)
        return white, red, shake, k, rim


# --------------------------------------------------------------------------
# FX objects
# --------------------------------------------------------------------------

class Particle:
    __slots__ = ('kind', 'x', 'y', 'vx', 'vy', 'life', 'age', 'size', 'drag', 'grav', 'seed', 'col')

    def __init__(self, kind, x, y, vx, vy, life, size, drag, grav, seed, col=None):
        self.kind, self.x, self.y, self.vx, self.vy = kind, x, y, vx, vy
        self.life, self.age, self.size, self.drag, self.grav = life, 0, size, drag, grav
        self.seed, self.col = seed, col


class Particles:
    def __init__(self):
        self.items: list[Particle] = []

    def step(self):
        alive = []
        for p in self.items:
            p.age += 1
            if p.age >= p.life:
                continue
            f = math.exp(-p.drag * DT)
            p.vx *= f
            p.vy = p.vy * f + p.grav * DT
            p.x += p.vx * DT
            p.y += p.vy * DT
            if p.kind in ('blood', 'chip') and p.y > GROUND_Y - 1:
                p.y = GROUND_Y - 1
                p.vy *= -0.25
                p.vx *= 0.5
            alive.append(p)
        self.items = alive

    def draw(self, bufs: F.Buffers, w2r):
        S = w2r.S
        for p in self.items:
            k = p.age / p.life
            x, y = w2r(p.x, p.y)
            speed = math.hypot(p.vx, p.vy)
            if p.kind == 'spark':
                hot = HIT_PALETTE['spark_hot'] if k < 0.25 else (HIT_PALETTE['spark_mid'] if k < 0.6 else HIT_PALETTE['spark_cool'])
                length = max(p.size * 2.2, speed * 0.030) * S
                d = (p.vx / (speed + 1e-6), p.vy / (speed + 1e-6))
                F.paint_spindle(bufs, 'top', (x - d[0] * length * 0.3, y - d[1] * length * 0.3), d, length,
                                p.size * S, (1.0, 0.98, 0.9), hot, gain=(1 - k) ** 0.8 * 1.25)
            elif p.kind == 'mote':
                col = p.col or (0.6, 0.85, 1.0)
                F.paint_glow(bufs, 'top', (x, y), p.size * S, col, gain=(1 - k) * 0.9 + 0.2)
                F.paint_glow(bufs, 'top', (x, y), p.size * S * 0.35, (1, 1, 1), gain=0.9 * (1 - k))
            elif p.kind == 'blood':
                d = math.atan2(p.vy, p.vx)
                stretch = 1 + min(2.2, speed / 260)
                F.paint_disc(bufs, 'front', (x, y), p.size * S * stretch, p.size * S, d,
                             HIT_PALETTE['blood'], 0.92 * (1 - k ** 3))
                F.paint_disc(bufs, 'front', (x - math.cos(d) * p.size * S * 0.4, y - math.sin(d) * p.size * S * 0.4),
                             p.size * S * 0.45, p.size * S * 0.35, d, HIT_PALETTE['blood_hi'], 0.7 * (1 - k ** 2))
            elif p.kind == 'chip':
                F.paint_disc(bufs, 'front', (x, y), p.size * S, p.size * S * 0.7, p.seed + p.age * 0.4,
                             (0.20, 0.18, 0.17), 0.95 * (1 - k ** 4))
            elif p.kind == 'dust':
                r = p.size * S * (0.6 + 1.4 * k ** 0.6)
                F.paint_blob(bufs, 'front', (x, y), r, p.col or (0.42, 0.37, 0.33), 0.42 * (1 - k) ** 1.4,
                             seed=p.seed, grain=0.8, stretch=(1.35, 0.85))
            elif p.kind == 'mist':
                r = p.size * S * (0.7 + 1.1 * k ** 0.5)
                F.paint_blob(bufs, 'front', (x, y), r, HIT_PALETTE['mist'], 0.45 * (1 - k) ** 1.6,
                             seed=p.seed, grain=0.9)


class SlashTrail:
    """Blade light swept around the grip: its head is always the drawn blade tip."""

    def __init__(self, player: Player, index: int, start: int, name: str):
        self.p, self.index, self.start, self.name = player, index, start, name
        self.m = MOVES[name]
        self.tr = self.m['trail']
        self.radius = PROFILE['length'] * self.tr.get('reach', 1.06)

    def center_world(self, lt: float):
        # Follow the grip through the cut, then stay put so follow-through poses don't drag the light.
        hand, _ = self.p.hand_world(self.start + min(lt, self.tr.get('anchor', self.tr['t1'])))
        return hand

    def alive(self) -> bool:
        lt = self.p.ptime - self.start
        return lt <= self.tr['t1'] + self.tr['life']

    def theta_at(self, lt: float) -> float:
        d, th, _, _ = self.p.blade(self.start + lt)
        if th is not None and self.m.get('ground_clamp'):
            d, th = self.p.clamp_ground(self.start + lt, d, th, self.m)
        return th

    def draw(self, bufs: F.Buffers, w2r):
        lt = self.p.view_t() - self.start
        t0, t1 = self.tr['t0'], self.tr['t1']
        if lt < t0:
            return
        sweep = self.m['sweep']
        th_start = self.theta_at(t0)
        head = self.theta_at(min(lt, t1))
        if head is None or th_start is None:
            return
        if 'from' in self.tr and (th_start - self.tr['from']) * sweep < 0:
            th_start = self.tr['from']
        if 'to' in self.tr and (head - self.tr['to']) * sweep > 0:
            head = self.tr['to']
        travelled = (head - th_start) * sweep
        span = min(self.tr['span'], max(0.0, travelled))
        age = 0.0
        if lt > t1:
            age = min(1.0, (lt - t1) / self.tr['life'])
            span *= (1 - 0.55 * age)
        if span < 1:
            return
        tail = head - span * sweep
        center = w2r(*self.center_world(lt))
        S = w2r.S
        R = self.radius * S
        pal = PALETTES[self.tr['palette']]
        gain = self.tr['gain'] * (1 - age) ** 0.9
        basis = self.m['plane']
        F.paint_crescent(bufs, center, basis, R, head, tail, sweep, self.tr['thick'], pal,
                         gain=gain, age=age, core_px=2.6, seed=self.index * 3 + 1)
        # Secondary hairlines give the arc speed and depth.
        F.paint_crescent(bufs, center, basis, R * 0.80, head - 12 * sweep, head - span * 0.62 * sweep, sweep,
                         0.06, pal, gain=gain * 0.55, age=age, core_px=1.6, seed=self.index * 3 + 2)
        F.paint_crescent(bufs, center, basis, R * 1.07, head - 4 * sweep, head - span * 0.42 * sweep, sweep,
                         0.035, pal, gain=gain * 0.45, age=age, core_px=1.4, seed=self.index * 3 + 3)


class HitSpark:
    """Impact at the true blade/target contact, oriented by the cut."""

    def __init__(self, contact, blade_dir, tangent, knock_dir, heavy, cut,
                 particles: Particles, rng: np.random.Generator, iai=False):
        self.c = contact
        self.bd = blade_dir / (np.linalg.norm(blade_dir) + 1e-9)
        self.tg = tangent / (np.linalg.norm(tangent) + 1e-9)
        self.kd = np.asarray(knock_dir, np.float64)
        self.heavy, self.iai = heavy, iai
        # cut = (world centre, plane basis, radius, theta, sweep): the swing-plane
        # circle that passes exactly through the contact point.
        self.cut = cut
        self.age = 0
        self.life = 26 if heavy else 18
        n_rays = 9 if heavy else 7
        base = math.atan2(self.bd[1], self.bd[0])
        self.rays = []
        for i in range(n_rays):
            if i < 2:
                ang = base + (0 if i == 0 else math.pi) + rng.normal(0, 0.05)
                length = (125 if heavy else 92) * rng.uniform(0.85, 1.1)
                width = 6.5 if heavy else 5.0
            else:
                ang = base + rng.uniform(-math.pi, math.pi)
                length = (62 if heavy else 44) * rng.uniform(0.45, 1.0)
                width = 3.6 if heavy else 2.8
            self.rays.append((ang, length, width))
        # Sparks follow the edge's travel and the push direction.
        spray = self.tg * 0.75 + self.kd * 0.65
        spray /= np.linalg.norm(spray) + 1e-9
        sa = math.atan2(spray[1], spray[0])
        for _ in range(30 if heavy else 18):
            a = sa + rng.normal(0, 0.55)
            sp = rng.uniform(320, 820 if heavy else 650)
            particles.items.append(Particle('spark', contact[0], contact[1], math.cos(a) * sp, math.sin(a) * sp,
                                            int(rng.integers(9, 22)), rng.uniform(1.5, 2.6), 5.0, 900, 0))
        for _ in range(10 if heavy else 6):
            a = sa + rng.normal(0, 0.45)
            sp = rng.uniform(110, 330)
            particles.items.append(Particle('blood', contact[0], contact[1], math.cos(a) * sp, math.sin(a) * sp - 60,
                                            int(rng.integers(18, 32)), rng.uniform(1.3, 2.4), 2.0, 1100, 0))
        particles.items.append(Particle('mist', contact[0] + spray[0] * 6, contact[1] + spray[1] * 6,
                                        spray[0] * 40, spray[1] * 40 - 10, 16, 11 if heavy else 8, 3, -20,
                                        int(rng.integers(0, 999))))

    def alive(self):
        return self.age < self.life

    def step(self):
        self.age += 1

    def draw(self, bufs: F.Buffers, w2r):
        S = w2r.S
        a = self.age
        c = w2r(*self.c)
        pal = HIT_PALETTE
        big = 1.35 if self.heavy else 1.0
        # 1) contact flash: small white-hot core, warm halo
        if a < 4:
            k = 1 - a / 4
            F.paint_glow(bufs, 'top', c, 10 * S * big * (1 + 0.25 * a), pal['glow'], gain=0.75 * k)
            F.paint_glow(bufs, 'top', c, 4.0 * S * big, pal['core'], gain=2.0 * k)
        # 2) starburst: two long rays along the blade, short random spikes
        if a < 6:
            k = (1 - a / 6) ** 1.3
            grow = 0.55 + 0.45 * min(1, (a + 1) / 2)
            rays = [(ang, L * S * grow, w * S * (0.35 + 0.65 * k)) for ang, L, w in self.rays]
            F.paint_starburst(bufs, 'top', c, rays, pal['core'], pal['glow'], gain=1.1 * k)
        # 3) cut mark: a sharp arc on the swing circle through the contact point
        if self.cut is not None and a < 13:
            k = a / 13
            cw, basis, radius, theta, sweep = self.cut
            center = w2r(*cw)
            head = theta + 34 * sweep * (0.55 + 0.45 * min(1, a / 2))
            tail = theta - 46 * sweep
            F.paint_crescent(bufs, center, basis, radius * S * 1.04, head, tail, sweep, 0.16 * big,
                             {'core': pal['core'], 'main': (1.0, 0.82, 0.52), 'deep': (0.95, 0.30, 0.10)},
                             gain=2.1 * (1 - k) ** 1.1, age=k * 0.85, core_px=3.6 * big, seed=91,
                             layers=('top',), peak=0.5)
        # 4) shock ring, flattened across the cut
        if a < 9:
            k = a / 9
            ang = math.atan2(self.bd[1], self.bd[0])
            F.paint_ring(bufs, 'top', c, (9 + 40 * big * k ** 0.6) * S, (2.2 - 1.4 * k) * S,
                         (1.0, 0.86, 0.66), gain=0.65 * (1 - k) ** 1.5, squash=0.5, angle=ang + math.pi / 2)


class GroundImpact:
    def __init__(self, x, particles: Particles, rng: np.random.Generator, scale: float):
        self.x, self.age, self.life = x, 0, 60
        self.S = scale
        self.crack = self._crack(rng)
        for i in range(14):
            side = -1 if i % 2 else 1
            sp = rng.uniform(60, 260)
            particles.items.append(Particle('dust', x + rng.normal(0, 6), GROUND_Y - rng.uniform(2, 10),
                                            side * sp, -rng.uniform(10, 60), int(rng.integers(26, 40)),
                                            rng.uniform(9, 15), 4.0, -40, int(rng.integers(0, 999))))
        for _ in range(10):
            a = -math.pi / 2 + rng.normal(0, 0.7)
            sp = rng.uniform(180, 420)
            particles.items.append(Particle('chip', x + rng.normal(0, 5), GROUND_Y - 3, math.cos(a) * sp,
                                            math.sin(a) * sp, int(rng.integers(22, 36)), rng.uniform(1.3, 2.4),
                                            0.8, 1400, rng.uniform(0, 6)))
        for _ in range(12):
            a = -math.pi / 2 + rng.normal(0, 0.9)
            sp = rng.uniform(250, 600)
            particles.items.append(Particle('spark', x, GROUND_Y - 4, math.cos(a) * sp, math.sin(a) * sp,
                                            int(rng.integers(8, 16)), rng.uniform(1.4, 2.2), 5.0, 1200, 0))

    def _crack(self, rng):
        S = self.S
        w, h = int(220 * S), int(46 * S)
        dark = Image.new('L', (w, h), 0)
        hot = Image.new('L', (w, h), 0)
        dd, dh = ImageDraw.Draw(dark), ImageDraw.Draw(hot)
        cx, cy = w / 2, h / 2
        for i in range(9):
            ang = rng.uniform(0, 2 * math.pi)
            pts = [(cx, cy)]
            x, y = cx, cy
            length = rng.uniform(40, 105) * S
            n = 6
            for j in range(n):
                ang += rng.normal(0, 0.35)
                step = length / n
                x += math.cos(ang) * step
                y += math.sin(ang) * step * 0.32
                pts.append((x, y))
            for j in range(len(pts) - 1):
                width = max(1, int((3.2 - j * 0.45) * S))
                dd.line([pts[j], pts[j + 1]], fill=230, width=width)
                dh.line([pts[j], pts[j + 1]], fill=255, width=max(1, width // 2))
        dd.ellipse((cx - 16 * S, cy - 5 * S, cx + 16 * S, cy + 5 * S), fill=200)
        dh.ellipse((cx - 9 * S, cy - 3 * S, cx + 9 * S, cy + 3 * S), fill=255)
        from scipy.ndimage import gaussian_filter
        da = gaussian_filter(np.asarray(dark, np.float32) / 255.0, 0.7)
        ha = gaussian_filter(np.asarray(hot, np.float32) / 255.0, 1.2)
        return da, ha

    def alive(self):
        return self.age < self.life

    def step(self):
        self.age += 1

    def draw(self, bufs: F.Buffers, w2r):
        S = w2r.S
        da, ha = self.crack
        h, w = da.shape
        cx, cy = w2r(self.x, GROUND_Y + 2)
        x0, y0 = int(cx - w / 2), int(cy - h / 2)
        hit = bufs.box(x0, y0, x0 + w, y0 + h)
        if hit is None:
            return
        sl = hit[0]
        sy, sx = sl
        crop_y = slice(sy.start - y0, sy.stop - y0)
        crop_x = slice(sx.start - x0, sx.stop - x0)
        fade = 1 - F.smoothstep(30, 60, np.float64(self.age))
        F.add_matter(bufs.mat['ground'], sl, da[crop_y, crop_x] * 0.85 * fade, (0.05, 0.035, 0.04))
        heat = max(0.0, 1 - self.age / 18.0) ** 1.4
        F.add_light(bufs.add['back'], sl, ha[crop_y, crop_x] * heat * 1.4, (1.0, 0.55, 0.22))
        a = self.age
        if a < 12:
            k = a / 12
            F.paint_ring(bufs, 'back', (cx, cy), (14 + 120 * k ** 0.55) * S, (3.5 - 2.5 * k) * S,
                         (1.0, 0.82, 0.6), gain=0.95 * (1 - k) ** 1.4, squash=F.SIN_T)
            F.paint_glow(bufs, 'top', (cx, cy - 6 * S), 30 * S, (1.0, 0.6, 0.3), gain=0.7 * (1 - k) ** 2,
                         squash=0.45)


class Afterimage:
    def __init__(self, key, root_x, scale, tint, life=14):
        self.key, self.x, self.S, self.tint, self.age, self.life = key, root_x, scale, tint, 0, life

    def alive(self):
        return self.age < self.life

    def step(self):
        self.age += 1


class IaiFlash:
    """The quick-draw signature: a frozen horizontal flash line, then delayed cuts."""

    def __init__(self, contact, particles: Particles, rng, scale, hitstop):
        self.c, self.age, self.life, self.S = contact, 0, 40, scale
        self.hs = hitstop
        self.rng = rng
        self.parts = particles
        self.cuts_spawned = 0

    def alive(self):
        return self.age < self.life

    def step(self):
        self.age += 1
        burst_at = [self.hs, self.hs + 3, self.hs + 6]
        if self.cuts_spawned < 3 and self.age >= burst_at[self.cuts_spawned]:
            rng = self.rng
            for _ in range(14):
                a = rng.uniform(-math.pi, math.pi)
                sp = rng.uniform(250, 650)
                self.parts.items.append(Particle('spark', self.c[0], self.c[1], math.cos(a) * sp, math.sin(a) * sp,
                                                 int(rng.integers(8, 18)), rng.uniform(1.5, 2.6), 5.5, 700, 0))
            self.cuts_spawned += 1

    def dim(self) -> float:
        if self.age < self.hs:
            return 1.0
        return max(0.0, 1 - (self.age - self.hs) / 10.0)

    def draw(self, bufs: F.Buffers, w2r):
        S = w2r.S
        a = self.age
        c = w2r(*self.c)
        col = (0.55, 0.85, 1.0)
        if a < self.hs + 4:
            k = min(1.0, (a + 1) / 2)
            fade = 1.0 if a < self.hs else 1 - (a - self.hs) / 4
            F.paint_spindle(bufs, 'top', c, (1, -0.02), 900 * S * k, 5.5 * S * fade + 1, (1, 1, 1), col,
                            gain=1.5 * fade, glow_width=3.5)
        angles = [-0.42, 0.38, -0.05]
        for i in range(self.cuts_spawned):
            t0 = [self.hs, self.hs + 3, self.hs + 6][i]
            k = (a - t0) / 10
            if 0 <= k < 1:
                ang = angles[i]
                d = (math.cos(ang), math.sin(ang))
                F.paint_spindle(bufs, 'top', c, d, (150 + 60 * k) * S, 5 * S * (1 - k) + 1, (1, 1, 1), col,
                                gain=1.5 * (1 - k) ** 1.2)
                F.paint_glow(bufs, 'top', c, 9 * S, col, gain=0.5 * (1 - k) ** 2)
                F.paint_ring(bufs, 'top', c, (12 + 60 * k ** 0.6) * S, 2.2 * S, (0.75, 0.92, 1.0),
                             gain=0.8 * (1 - k) ** 1.5, squash=0.6, angle=ang + math.pi / 2)


# --------------------------------------------------------------------------
# Scene
# --------------------------------------------------------------------------

class W2R:
    def __init__(self, cam_x, cam_y, S):
        self.cx, self.cy, self.S = cam_x, cam_y, S

    def __call__(self, x, y):
        return ((x - self.cx) * self.S, (y - self.cy) * self.S)


class Scene:
    def __init__(self, view, schedule, player_x, target_x, scale=2.0, seed=5, debug=False, tail=40):
        self.vx, self.vy, self.vw, self.vh = view
        self.S = scale
        self.W, self.H = int(self.vw * scale), int(self.vh * scale)
        self.w, self.h = self.W, self.H
        bg = Image.open(BG).convert('RGB')
        self.bg = np.asarray(bg.resize((int(bg.width * scale), int(bg.height * scale)),
                                       Image.Resampling.BICUBIC)).astype(np.float32) / 255.0
        self.player = Player(player_x, schedule, scale)
        self.target = Target(target_x, scale) if target_x is not None else None
        self.parts = Particles()
        self.objs: list = []
        self.trails: list[SlashTrail] = []
        self.after: list[Afterimage] = []
        self.hitstop = 0
        self.shakes: list = []
        self.real = 0
        self.rng = np.random.default_rng(seed)
        self.debug = debug
        self.contacts: list[dict] = []
        self.started: set[int] = set()
        last = max(s + MOVES[n]['length'] for s, n in schedule)
        self.length = last + tail
        self.dbg_marks: list = []

    # ---- simulation -----------------------------------------------------
    def step(self):
        frozen = self.hitstop > 0
        if frozen:
            self.hitstop -= 1
        p = self.player
        if not frozen:
            if p.resume_hold:
                # First tick after hit-stop shows the rest of the contact tick.
                p.resume_hold = False
                p.freeze_t = None
            else:
                p.freeze_t = None
                prev = p.ptime
                p.ptime += 1
                self._detect(prev, p.ptime)
        cur = p.current()
        if cur is not None:
            i, start, name = cur
            if i not in self.started:
                self.started.add(i)
                self.trails.append(SlashTrail(p, i, start, name))
            m = MOVES[name]
            lt = p.ptime - start
            if not frozen and 'charge' in m and m['charge'][0] <= lt < m['charge'][1] and lt % 2 == 0:
                self._charge_mote(lt, m)
            if not frozen and 'afterimage' in m and m['afterimage'][0] <= lt < m['afterimage'][1]:
                self.after.append(Afterimage(p.pose_key(p.ptime), p.root_x(), self.S, (0.35, 0.75, 1.0)))
        if self.target:
            self.target.step(frozen)
        self.parts.step()
        for o in self.objs:
            o.step()
        for a in self.after:
            a.step()
        self.objs = [o for o in self.objs if o.alive()]
        self.after = [a for a in self.after if a.alive()]
        self.trails = [t for t in self.trails if t.alive()]
        for s in self.shakes:
            s[2] += 1
        self.shakes = [s for s in self.shakes if s[2] < s[3]]
        self.real += 1

    def _charge_mote(self, lt, m):
        hand, _ = self.player.hand_world(self.player.ptime)
        rng = self.rng
        for _ in range(2):
            ang = rng.uniform(0, 2 * math.pi)
            dist = rng.uniform(40, 70)
            x, y = hand[0] + math.cos(ang) * dist, hand[1] + math.sin(ang) * dist * 0.7
            life = int(rng.integers(9, 13))
            vx, vy = (hand[0] - x) / (life * DT) * 0.9, (hand[1] - y) / (life * DT) * 0.9
            self.parts.items.append(Particle('mote', x, y, vx, vy, life, rng.uniform(2.0, 3.2), 0.0, 0.0, 0,
                                             (0.45, 0.82, 1.0)))

    def _detect(self, t_prev: int, t_now: int):
        p, tg = self.player, self.target
        cur = p.current(t_now)
        if cur is None:
            return
        i, start, name = cur
        m = MOVES[name]
        for sub in range(1, 5):
            t = t_prev + sub / 4.0
            lt = t - start
            hand, d, th, tan, nm, pts = p.blade_points(t)
            if m.get('ground_clamp') and th is not None and i not in p.ground_done:
                if pts[-1][1] >= GROUND_Y - 2:
                    p.ground_done.add(i)
                    cd, _ = p.clamp_ground(t, d, th, m)
                    tip_x = hand[0] + F.project(cd * PROFILE['length'])[0]
                    self.objs.append(GroundImpact(tip_x, self.parts, self.rng, self.S))
                    self.shakes.append([3.0, (0.0, 1.0), 0, 14])
            if tg is None or i in p.hit_done or th is None:
                continue
            w0, w1 = m['hit']['window']
            if not (w0 <= lt <= w1):
                continue
            inside = [q for q in pts if tg.alpha_at(*q) > 0.55]
            if not inside:
                continue
            p.hit_done.add(i)
            cx = sum(q[0] for q in inside) / len(inside)
            cy = sum(q[1] for q in inside) / len(inside)
            bd = F.project(d)
            tg2 = F.project(tan)
            hit = m['hit']
            trail = next((tr for tr in self.trails if tr.index == i), None)
            cut = None
            if trail is not None:
                cw = hand
                u, v = m['plane']
                M = np.array([[F.project(u)[0], F.project(v)[0]], [F.project(u)[1], F.project(v)[1]]])
                ab = np.linalg.solve(M, np.array([cx - cw[0], cy - cw[1]]))
                cut = (cw, m['plane'], float(np.hypot(*ab)), math.degrees(math.atan2(ab[1], ab[0])), m['sweep'])
            if hit.get('iai'):
                self.objs.append(IaiFlash((cx, cy), self.parts, self.rng, self.S, hit['hitstop']))
                self.objs.append(HitSpark((cx, cy), bd, tg2, (1.0, -0.1), True, cut, self.parts, self.rng, iai=True))
            else:
                self.objs.append(HitSpark((cx, cy), bd, tg2, (1.0, -0.15), hit['heavy'], cut, self.parts, self.rng))
            # Hold the exact contact pose/blade on screen for the whole hit-stop.
            p.freeze_t = t
            p.resume_hold = True
            self.hitstop = hit['hitstop']
            tg.on_hit(hit, self.real, (cx, cy))
            sd = tg2 * 0.4 + np.array([1.0, 0.0])
            self.shakes.append([hit['shake'], tuple(sd / np.linalg.norm(sd)), 0, 12 if hit['heavy'] else 8])
            self.contacts.append({'move': name, 'tick': self.real, 'local_t': round(lt, 2), 'theta': round(th, 1),
                                  'contact': [round(cx, 1), round(cy, 1)], 'blade_samples_inside': len(inside),
                                  'target_x': round(tg.x(), 1)})
            self.dbg_marks.append(((cx, cy), [q for q in pts], self.real))
            return

    # ---- rendering ------------------------------------------------------
    def shake_offset(self):
        ox = oy = 0.0
        for amp, d, age, life in self.shakes:
            k = (1 - age / life) ** 2
            osc = math.cos(age * 2.1)
            ox += amp * k * d[0] * osc
            oy += amp * k * d[1] * osc + amp * 0.25 * k * math.sin(age * 2.9)
        return ox, oy

    def render(self) -> np.ndarray:
        S = self.S
        ox, oy = self.shake_offset()
        cam_x, cam_y = self.vx + ox, self.vy + oy
        w2r = W2R(cam_x, cam_y, S)
        bx, by = int(round(cam_x * S)), int(round(cam_y * S))
        rgb = self.bg[by:by + self.H, bx:bx + self.W].copy()
        bufs = F.Buffers(self.W, self.H)
        p, tg = self.player, self.target
        # Dim world during iai freeze.
        dim = max([o.dim() for o in self.objs if isinstance(o, IaiFlash)] or [0.0])

        for o in self.objs:
            o.draw(bufs, w2r)
        for tr in self.trails:
            tr.draw(bufs, w2r)
        self.parts.draw(bufs, w2r)

        F.over(rgb, bufs.mat['ground'])
        # contact shadows
        px, py = w2r(p.root_x(), GROUND_Y)
        self._shadow(rgb, px, py, 44 * S, 8 * S, 0.42)
        if tg:
            tx, ty = w2r(tg.x(), GROUND_Y)
            self._shadow(rgb, tx, ty, 36 * S * (1 + tg.hop_y / -160), 7 * S, 0.40)
            self._draw_target(rgb, w2r)
        F.over(rgb, bufs.mat['back'])
        if dim > 0:
            rgb *= (1 - 0.48 * dim)
            rgb[..., 2] += 0.03 * dim
        F.screen_add(rgb, bufs.add['back'])
        for a in self.after:
            sp = pose(a.key[0], a.key[1], S)
            k = 1 - a.age / a.life
            pm = premult_of(('p', a.key), sp.image)
            ax, ay = w2r(a.x, GROUND_Y)
            ghost = pm * (0.42 * k)
            paste(rgb, ghost, ax + sp.offset[0], ay + sp.offset[1], mul=(0.25, 0.25, 0.3), add=tuple(c * 0.5 * k for c in a.tint))
        self._draw_player(rgb, w2r)
        F.over(rgb, bufs.mat['front'])
        light = bufs.add['front'] + bufs.add['top']
        F.screen_add(rgb, light)
        F.screen_add(rgb, F.bloom(np.minimum(light + bufs.add['back'], 1.1), S / 2) * 0.55)
        if self.debug:
            self._debug(rgb, w2r)
        return (np.clip(rgb, 0, 1) * 255 + 0.5).astype(np.uint8)

    def _shadow(self, rgb, cx, cy, rx, ry, alpha):
        hit = F.Buffers.box(self, cx - rx * 1.6, cy - ry * 2, cx + rx * 1.6, cy + ry * 2)
        if hit is None:
            return
        sl, xs, ys = hit
        d = ((xs - cx) / rx) ** 2 + ((ys - cy) / ry) ** 2
        a = np.exp(-d * 1.6)[..., None] * alpha
        rgb[sl] = rgb[sl] * (1 - a)

    def _draw_target(self, rgb, w2r):
        tg = self.target
        sp = tg.sprite()
        white, red, shake, k, rim = tg.look(self.real)
        img = sp.image
        ox, oy = sp.offset
        if k > 0:
            sx, sy = 1 - (0.13 if tg.heavy else 0.09) * k, 1 + (0.08 if tg.heavy else 0.05) * k
            nw, nh = max(1, round(img.width * sx)), max(1, round(img.height * sy))
            img = img.resize((nw, nh), Image.Resampling.BILINEAR)
            ox, oy = ox * sx, oy * sy
        pm = _premult(img)
        if white > 0 or red > 0 or rim > 0:
            a = pm[..., 3:4]
            col = pm[..., :3]
            # Red flush keeps the painted detail (multiplicative), white is a short partial flash.
            col = col * (1 - red * np.array([0.0, 0.42, 0.46], np.float32))
            col = col * (1 - white) + a * white * np.array([1.0, 0.97, 0.92], np.float32)
            if rim > 0:
                # Rim light from the impact: only edges facing the blade, fading with distance.
                sh = int(4 * self.S)
                shifted = np.zeros_like(a)
                shifted[:, sh:] = a[:, :-sh]
                edge = np.clip(a - shifted, 0, 1)
                rx, ry = tg.contact_rel
                cxl, cyl = rx * self.S - ox, (ry - tg.hop_y) * self.S - oy
                yy, xx = np.mgrid[0:a.shape[0], 0:a.shape[1]]
                fall = np.exp(-((xx - cxl) ** 2 + (yy - cyl) ** 2) / (2 * (52 * self.S) ** 2))[..., None]
                col = col + edge * fall * rim * 0.9 * np.array([1.0, 0.88, 0.70], np.float32)
            pm = np.concatenate([np.clip(col, 0, None), a], -1)
        x, y = w2r(tg.x(), GROUND_Y + tg.hop_y)
        paste(rgb, pm, x + ox + shake * self.S, y + oy)

    def _draw_player(self, rgb, w2r):
        p = self.player
        t = p.view_t()
        sheet, cell = p.pose_key(t)
        sp = pose(sheet, cell, self.S)
        root = w2r(p.root_x(t), GROUND_Y)
        hand_r = (root[0] + sp.hand[0] * self.S, root[1] + sp.hand[1] * self.S)
        d, th, tan, name = p.blade(t)
        m = MOVES.get(name) if name else None
        if m and m.get('ground_clamp') and th is not None:
            d, th = p.clamp_ground(t, d, th, m)
        if tan is not None:
            p.edge = tan
        edge = p.edge if tan is None else tan
        depth = F.view_depth(d)
        layer = sp.layer
        if depth < -0.30:
            layer = 'back'
        elif depth > 0.25:
            layer = 'front'
        ghosts = []
        if th is not None and m is not None and p.freeze_t is None:
            lt = t - p.current(t)[1]
            tr = m['trail']
            if tr['t0'] <= lt <= tr['t1'] - 1:
                for g, alpha in ((1.4, 0.26), (0.7, 0.42)):
                    gd, gth, gtan, _ = p.blade(t - g)
                    if gth is not None:
                        ghosts.append((gd, gtan, alpha))
        weapon = []
        for gd, gtan, alpha in ghosts:
            weapon.append(draw_katana(hand_r, gd, gtan, self.S, alpha=alpha, tint=(0.75, 0.88, 1.0, 0.55)))
        weapon.append(draw_katana(hand_r, d, edge, self.S))
        body = premult_of(('p', (sheet, cell)), sp.image)
        if layer == 'back':
            for arr, (x0, y0), _ in weapon:
                paste(rgb, arr, x0, y0)
        paste(rgb, body, root[0] + sp.offset[0], root[1] + sp.offset[1])
        if layer != 'back':
            for arr, (x0, y0), _ in weapon:
                paste(rgb, arr, x0, y0)
            # Restore the painted fist over the grip.
            r = 8.5 * self.S
            bx = int(round(hand_r[0] - (root[0] + sp.offset[0]) - r))
            by = int(round(hand_r[1] - (root[1] + sp.offset[1]) - r))
            size = int(2 * r)
            patch = np.zeros((size, size, 4), np.float32)
            ys0, xs0 = max(0, by), max(0, bx)
            ys1, xs1 = min(body.shape[0], by + size), min(body.shape[1], bx + size)
            if ys1 > ys0 and xs1 > xs0:
                patch[ys0 - by:ys1 - by, xs0 - bx:xs1 - bx] = body[ys0:ys1, xs0:xs1]
                yy, xx = np.mgrid[0:size, 0:size]
                mask = np.clip(1.4 - np.hypot(xx - r, yy - r) / r * 1.4 + 0.35, 0, 1)[..., None]
                paste(rgb, patch * mask, hand_r[0] - r, hand_r[1] - r)

    def _debug(self, rgb, w2r):
        img = Image.fromarray((np.clip(rgb, 0, 1) * 255).astype(np.uint8))
        dr = ImageDraw.Draw(img)
        S = self.S
        for tr in self.trails:
            c = w2r(*tr.center_world(self.player.view_t() - tr.start))
            pts = []
            for th in range(0, 361, 6):
                q = F.project(F.plane_dir(tr.m['plane'], th)) * tr.radius * S
                pts.append((c[0] + q[0], c[1] + q[1]))
            dr.line(pts, fill=(80, 255, 140), width=1)
        hand, d, th, tan, nm, pts = self.player.blade_points(self.player.view_t())
        for q in pts:
            r = w2r(*q)
            dr.ellipse((r[0] - 2, r[1] - 2, r[0] + 2, r[1] + 2), outline=(255, 230, 60))
        for (cx, cy), _, tick in self.dbg_marks:
            if 0 <= self.real - tick < 12:
                c = w2r(cx, cy)
                dr.line((c[0] - 12, c[1], c[0] + 12, c[1]), fill=(255, 40, 200), width=3)
                dr.line((c[0], c[1] - 12, c[0], c[1] + 12), fill=(255, 40, 200), width=3)
        if self.target:
            sp = self.target.sprite()
            x, y = w2r(self.target.x(), GROUND_Y + self.target.hop_y)
            box = sp.image.getbbox()
            if box:
                dr.rectangle((x + sp.offset[0] + box[0], y + sp.offset[1] + box[1],
                              x + sp.offset[0] + box[2], y + sp.offset[1] + box[3]), outline=(255, 90, 90))
        rgb[...] = np.asarray(img).astype(np.float32) / 255.0
