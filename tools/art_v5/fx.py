"""Offline FX painter: analytic slash crescents, impact streaks and particles.

All painters work on float32 accumulators in render pixels and only touch
the bounding box of the effect. Additive buffers hold light (slash, sparks);
premultiplied RGBA buffers hold matter (blood, dust, crack decals).
"""
from __future__ import annotations

import math

import numpy as np
from scipy.ndimage import gaussian_filter, map_coordinates

TAU = math.radians(20.0)
COS_T, SIN_T = math.cos(TAU), math.sin(TAU)


def project(v) -> np.ndarray:
    """Character-local 3D (x forward, y down, z toward camera) to screen."""
    return np.array([v[0], v[1] * COS_T + v[2] * SIN_T], dtype=np.float64)


def view_depth(v) -> float:
    return float(v[2] * COS_T - v[1] * SIN_T)


def plane(beta_deg: float, gamma_deg: float):
    """Swing plane basis. beta tilts the near side down (90 = screen plane),
    gamma tilts the forward side down. d(theta) = cos*u + sin*v."""
    b, g = math.radians(beta_deg), math.radians(gamma_deg)
    u = np.array([math.cos(g), math.sin(g), 0.0])
    v = np.array([-math.sin(b) * math.sin(g), math.sin(b) * math.cos(g), math.cos(b)])
    return u, v


def plane_dir(basis, theta_deg: float) -> np.ndarray:
    u, v = basis
    t = math.radians(theta_deg)
    return math.cos(t) * u + math.sin(t) * v


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def _noise(size: int, sigma: float, seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    n = gaussian_filter(rng.random((size, size)), sigma, mode='wrap')
    n -= n.min()
    return n / max(1e-6, n.max())


NOISE_A = (_noise(512, 2.0, 7) * 0.55 + _noise(512, 7.0, 8) * 0.45)
NOISE_B = _noise(256, 4.0, 11)


def sample_noise(tex: np.ndarray, x: np.ndarray, y: np.ndarray) -> np.ndarray:
    return map_coordinates(tex, [y % tex.shape[0], x % tex.shape[1]], order=1, mode='wrap')


class Buffers:
    """Per-frame accumulators grouped by depth relative to the player body."""

    def __init__(self, w: int, h: int):
        self.w, self.h = w, h
        self.add = {k: np.zeros((h, w, 3), np.float32) for k in ('back', 'front', 'top')}
        self.mat = {k: np.zeros((h, w, 4), np.float32) for k in ('ground', 'back', 'front')}

    def box(self, x0, y0, x1, y1):
        x0, y0 = max(0, int(math.floor(x0))), max(0, int(math.floor(y0)))
        x1, y1 = min(self.w, int(math.ceil(x1))), min(self.h, int(math.ceil(y1)))
        if x1 <= x0 or y1 <= y0:
            return None
        ys, xs = np.mgrid[y0:y1, x0:x1].astype(np.float32)
        return (slice(y0, y1), slice(x0, x1)), xs + 0.5, ys + 0.5


def _color(c) -> np.ndarray:
    if isinstance(c, str):
        c = c.lstrip('#')
        return np.array([int(c[i:i + 2], 16) / 255.0 for i in (0, 2, 4)], np.float32)
    return np.asarray(c, np.float32)


def add_light(buf: np.ndarray, sl, intensity: np.ndarray, color) -> None:
    buf[sl] += intensity[..., None] * _color(color)


def add_matter(buf: np.ndarray, sl, alpha: np.ndarray, color) -> None:
    """Premultiplied 'over' of a flat colour with per-pixel alpha."""
    a = np.clip(alpha, 0, 1)[..., None]
    col = _color(color)
    dst = buf[sl]
    dst[..., :3] = col * a + dst[..., :3] * (1 - a)
    dst[..., 3:] = a + dst[..., 3:] * (1 - a)


# --------------------------------------------------------------------------
# Slash crescent
# --------------------------------------------------------------------------

def paint_crescent(bufs: Buffers, center, basis, radius: float, head: float, tail: float,
                   sweep: int, thickness: float, palette: dict, gain: float = 1.0,
                   age: float = 0.0, core_px: float = 2.4, seed: int = 0,
                   layers=('back', 'front'), streak_scale: float = 1.0,
                   peak: float = 0.28) -> None:
    """Paint a planar arc band projected into screen space.

    head/tail are plane angles in degrees; sweep is the motion sign. thickness
    is a fraction of radius. age (0..1) dissolves the band from its tail and
    thins it, matching the way hand-drawn slash sprites burn out."""
    span = abs(head - tail)
    if span < 0.5 or gain <= 0.003:
        return
    u, v = basis
    pu, pv = project(u) * radius, project(v) * radius
    M = np.array([[pu[0], pv[0]], [pu[1], pv[1]]])
    if abs(np.linalg.det(M)) < 1e-3:
        return
    Minv = np.linalg.inv(M)
    ext = np.abs(pu) + np.abs(pv)
    hit = bufs.box(center[0] - ext[0] - 4, center[1] - ext[1] - 4,
                   center[0] + ext[0] + 4, center[1] + ext[1] + 4)
    if hit is None:
        return
    sl, xs, ys = hit
    dx, dy = xs - center[0], ys - center[1]
    a = Minv[0, 0] * dx + Minv[0, 1] * dy
    b = Minv[1, 0] * dx + Minv[1, 1] * dy
    r = np.sqrt(a * a + b * b) + 1e-6
    phi = np.degrees(np.arctan2(b, a))
    delta = ((head - phi) * sweep) % 360.0
    w = delta / span
    inside_span = w <= 1.0
    if not inside_span.any():
        return
    # Thickness profile: sharp head, belly just behind it, long tapering tail.
    wp = np.clip(w, 0, 1) ** 0.62
    shape = np.clip(4 * wp * (1 - wp), 0, 1) ** 0.85
    shape = np.where(w < peak * 0.25, shape * smoothstep(0, peak * 0.25, w) + 0.0, shape)
    thin = (1 - age) ** 0.7
    T = thickness * shape * thin + 1e-4
    vn = (1.0 - r) / T
    # Screen-space distance from the outer rim keeps the hot core line crisp.
    ga = Minv[0]
    gb = Minv[1]
    grx = (a * ga[0] + b * gb[0]) / r
    gry = (a * ga[1] + b * gb[1]) / r
    gscale = np.sqrt(grx * grx + gry * gry) + 1e-6
    dist_px = (1.0 - r) / gscale
    band = (vn >= -0.02) & (vn <= 1.25) & inside_span
    if not band.any():
        return
    s = np.clip(vn, 0, 1.25)
    wc = np.clip(w, 0, 1)
    along = (1 - wc) ** 1.6
    head = np.exp(-np.square(wc / 0.12))
    # Fine speed streaks run along the arc; the inner edge breaks up into wisps.
    streak = sample_noise(NOISE_A, phi * 0.7 * streak_scale + seed * 37.0, r * 700.0 * streak_scale + seed * 11.0)
    streak = 0.30 + 0.95 * smoothstep(0.28, 0.80, streak)
    n2 = sample_noise(NOISE_B, phi * 1.4 + seed * 13.0, r * 60.0 + seed * 5.0)
    inner_edge = 1 - smoothstep(0.50, 1.0, s + (n2 - 0.5) * 0.55)
    dissolve = smoothstep(age * 1.25 - 0.25, age * 1.25 + 0.05, n2 * 0.6 + (1 - wc) * 0.55) if age > 0 else 1.0
    k = gain * along * dissolve
    rim = np.exp(-np.square(np.maximum(dist_px, 0) / (core_px * (0.35 + 0.65 * shape)))) * band
    outer = np.exp(-np.square(np.minimum(dist_px, 0) / (core_px * 2.6))) * (dist_px < 0) * inside_span
    rim_i = rim * 1.55 * k * (1 + 1.1 * head) * (0.45 + 0.55 * (1 - wc))
    hot_i = np.exp(-np.square(s / 0.20)) * band * k * (0.95 + 1.4 * head)
    body_i = np.clip(1 - s, 0, 1) ** 1.9 * inner_edge * streak * band * k * 1.15
    deep_i = (np.clip(s, 0, 1) * np.clip(1 - s, 0, 1)) ** 0.7 * inner_edge * streak * band * k * 0.9
    glow_i = outer * k * 0.45
    hot_col = (_color(palette['core']) + _color(palette['main'])) * 0.5
    # Depth weighting splits the band in front of and behind the body.
    d3 = np.cos(np.radians(phi))[..., None] * u + np.sin(np.radians(phi))[..., None] * v
    z = d3[..., 2] * COS_T - d3[..., 1] * SIN_T
    front = smoothstep(-0.10, 0.10, z)
    weights = {'front': front, 'back': (1 - front) * 0.62}
    for layer in layers:
        wgt = weights.get(layer, 1.0) if len(layers) > 1 else 1.0
        tgt = bufs.add[layer]
        add_light(tgt, sl, rim_i * wgt, palette['core'])
        add_light(tgt, sl, hot_i * wgt, hot_col)
        add_light(tgt, sl, (body_i + glow_i) * wgt, palette['main'])
        add_light(tgt, sl, deep_i * wgt, palette['deep'])


# --------------------------------------------------------------------------
# Primitive light shapes
# --------------------------------------------------------------------------

def paint_spindle(bufs: Buffers, layer: str, c, direction, length: float, width: float,
                  core, glow, gain: float = 1.0, bias: float = 0.0, glow_width: float = 2.6) -> None:
    """Lens-shaped streak. bias>0 moves the fat part toward +direction."""
    if gain <= 0.003 or length < 1:
        return
    d = np.asarray(direction, np.float64)
    d = d / (np.linalg.norm(d) + 1e-9)
    half = length * 0.5
    reach = half + width * glow_width
    hit = bufs.box(c[0] - reach, c[1] - reach, c[0] + reach, c[1] + reach)
    if hit is None:
        return
    sl, xs, ys = hit
    dx, dy = xs - c[0], ys - c[1]
    al = (dx * d[0] + dy * d[1]) / half
    ac = (-dx * d[1] + dy * d[0])
    a2 = al - bias * (1 - al * al)
    hw = np.clip(1 - a2 * a2, 0, 1) ** 0.75 * width * 0.5 + 0.35
    inside = np.abs(al) < 1
    core_i = np.exp(-np.square(ac / hw) * 3.2) * inside
    glow_i = np.exp(-np.square(ac / (hw * glow_width)) * 1.2) * np.clip(1 - np.abs(al), 0, 1) ** 0.6
    add_light(bufs.add[layer], sl, core_i * gain, core)
    add_light(bufs.add[layer], sl, glow_i * gain * 0.55, glow)


def paint_glow(bufs: Buffers, layer: str, c, radius: float, color, gain: float = 1.0,
               squash: float = 1.0, angle: float = 0.0) -> None:
    if gain <= 0.003:
        return
    reach = radius * 3.0
    hit = bufs.box(c[0] - reach, c[1] - reach, c[0] + reach, c[1] + reach)
    if hit is None:
        return
    sl, xs, ys = hit
    dx, dy = xs - c[0], ys - c[1]
    ca, sa = math.cos(angle), math.sin(angle)
    px = dx * ca + dy * sa
    py = (-dx * sa + dy * ca) / max(0.05, squash)
    i = np.exp(-(px * px + py * py) / (2 * radius * radius))
    add_light(bufs.add[layer], sl, i * gain, color)


def paint_ring(bufs: Buffers, layer: str, c, radius: float, width: float, color,
               gain: float = 1.0, squash: float = 1.0, angle: float = 0.0, arc=None) -> None:
    if gain <= 0.003 or radius <= 0:
        return
    reach = radius + width * 3
    hit = bufs.box(c[0] - reach, c[1] - reach, c[0] + reach, c[1] + reach)
    if hit is None:
        return
    sl, xs, ys = hit
    dx, dy = xs - c[0], ys - c[1]
    ca, sa = math.cos(angle), math.sin(angle)
    px = dx * ca + dy * sa
    py = (-dx * sa + dy * ca) / max(0.05, squash)
    rr = np.sqrt(px * px + py * py)
    i = np.exp(-np.square((rr - radius) / width))
    if arc is not None:
        ang = np.degrees(np.arctan2(py, px))
        lo, hi = arc
        i = i * smoothstep(lo - 20, lo, ang) * (1 - smoothstep(hi, hi + 20, ang))
    add_light(bufs.add[layer], sl, i * gain, color)


def paint_starburst(bufs: Buffers, layer: str, c, rays, core, glow, gain: float = 1.0) -> None:
    """rays: list of (angle_rad, length, width)."""
    for ang, length, width in rays:
        d = (math.cos(ang), math.sin(ang))
        mid = (c[0] + d[0] * length * 0.42, c[1] + d[1] * length * 0.42)
        paint_spindle(bufs, layer, mid, d, length, width, core, glow, gain, bias=-0.45, glow_width=2.2)


def paint_blob(bufs: Buffers, key: str, c, radius: float, color, alpha: float,
               seed: int = 0, grain: float = 0.5, stretch=(1.0, 1.0)) -> None:
    """Soft noise-edged matter puff (dust, blood mist)."""
    if alpha <= 0.003:
        return
    reach = radius * 1.6
    hit = bufs.box(c[0] - reach * stretch[0], c[1] - reach * stretch[1],
                   c[0] + reach * stretch[0], c[1] + reach * stretch[1])
    if hit is None:
        return
    sl, xs, ys = hit
    dx, dy = (xs - c[0]) / stretch[0], (ys - c[1]) / stretch[1]
    rr = np.sqrt(dx * dx + dy * dy) / radius
    n = sample_noise(NOISE_B, xs * 0.9 + seed * 53, ys * 0.9 + seed * 29)
    edge = 1 - smoothstep(0.35, 1.0, rr + (n - 0.5) * grain)
    add_matter(bufs.mat[key], sl, edge * alpha, color)


def paint_disc(bufs: Buffers, key: str, c, rx: float, ry: float, angle: float, color, alpha: float) -> None:
    if alpha <= 0.003:
        return
    reach = max(rx, ry) + 2
    hit = bufs.box(c[0] - reach, c[1] - reach, c[0] + reach, c[1] + reach)
    if hit is None:
        return
    sl, xs, ys = hit
    dx, dy = xs - c[0], ys - c[1]
    ca, sa = math.cos(angle), math.sin(angle)
    px = (dx * ca + dy * sa) / max(0.3, rx)
    py = (-dx * sa + dy * ca) / max(0.3, ry)
    rr = np.sqrt(px * px + py * py)
    a = 1 - smoothstep(0.75, 1.0, rr)
    add_matter(bufs.mat[key], sl, a * alpha, color)


# --------------------------------------------------------------------------
# Final composite helpers
# --------------------------------------------------------------------------

def over(dst_rgb: np.ndarray, premult: np.ndarray) -> None:
    a = premult[..., 3:4]
    dst_rgb[...] = premult[..., :3] + dst_rgb * (1 - a)


def bloom(light: np.ndarray, scale: float) -> np.ndarray:
    small = light[::2, ::2]
    b1 = gaussian_filter(small, (3.0 * scale, 3.0 * scale, 0))
    b2 = gaussian_filter(small, (9.0 * scale, 9.0 * scale, 0))
    glow = b1 * 0.55 + b2 * 0.45
    return np.repeat(np.repeat(glow, 2, axis=0), 2, axis=1)[:light.shape[0], :light.shape[1]]


def screen_add(dst_rgb: np.ndarray, light: np.ndarray) -> None:
    """Additive light with a soft shoulder so hot cores stay white, not clipped flat."""
    x = dst_rgb + light
    knee = 0.82
    over_k = np.maximum(x - knee, 0)
    dst_rgb[...] = np.where(x > knee, knee + (1 - knee) * (1 - np.exp(-over_k / (1 - knee))), x)
