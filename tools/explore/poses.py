"""探索原型：动作关键帧（只描述骨架与武器方向，不含任何外观）。

attack1 对齐 V6 正手横斩时间轴：总长 30 tick，刀光窗口 [8,12)，接触参考 tick 9，前冲 [7,11,12]。
"""
from __future__ import annotations

import math

from puppet import build_keys


SWING_TILT = -28.0


def _tilt(v, tilt):
    t = math.radians(tilt)
    x, y, z = v
    return (x, y * math.cos(t) - z * math.sin(t), y * math.sin(t) + z * math.cos(t))


def flat(phi_deg, down=0.0, tilt=SWING_TILT):
    """挥砍面内的刀向：phi=0 朝前，+90 朝角色右侧（近镜头），-90 朝左侧；挥砍面绕前向轴倾斜 tilt。"""
    a = math.radians(phi_deg)
    return _tilt((math.cos(a), -down, math.sin(a)), tilt)


def lead_edge(phi_deg, tilt=SWING_TILT):
    a = math.radians(phi_deg)
    return _tilt((math.sin(a), 0.0, -math.cos(a)), tilt)


def look(pelvis_yaw, chest_yaw, k=0.8):
    return -(pelvis_yaw + chest_yaw) * k


READY = {
    "root_x": 0.0, "pelvis_h": 91.0, "pelvis_yaw": -8.0, "pelvis_lean": 6.0, "chest_yaw": -6.0,
    "chest_lean": 4.0, "head_yaw": look(-8, -6), "head_lean": -4.0,
    "hand_r": (24.0, 92.0, 22.0), "blade_dir": (0.85, -0.42, 0.18), "blade_edge": (0.3, 0.6, 0.0),
    "pole_r": (-0.4, -1.0, 0.6),
    "hand_l": (10.0, 96.0, -20.0), "pole_l": (-0.6, -1.0, -0.4),
    "foot_r": (22.0, 0.0, 9.0), "foot_l": (-24.0, 0.0, -9.0),
    "foot_r_dir": (1.0, 0.0, 0.15), "foot_l_dir": (0.8, 0.0, -0.6), "coat": (-2.0, 0.0, 0.0),
}

ATTACK1 = build_keys([
    (0, "inout", READY),
    (6, "inout", {
        "pelvis_h": 88.0, "pelvis_yaw": -18.0, "pelvis_lean": 8.0, "chest_yaw": -38.0, "chest_lean": 6.0,
        "head_yaw": look(-18, -38, 0.85), "hand_r": (-8.0, 114.0, 36.0),
        "blade_dir": flat(140, 0.15), "blade_edge": lead_edge(140), "pole_r": (-0.3, -1.0, 0.2),
        "hand_l": (32.0, 110.0, -12.0), "pole_l": (-0.2, -1.0, -0.6), "coat": (-1.0, 0.0, 2.0),
    }),
    (8, "linear", {
        "root_x": 3.0, "pelvis_yaw": -6.0, "chest_yaw": -14.0, "head_yaw": look(-6, -14, 0.85),
        "hand_r": (24.0, 115.0, 40.0), "blade_dir": flat(78), "blade_edge": lead_edge(78),
        "hand_l": (18.0, 108.0, -22.0), "foot_r": (26.0, 0.0, 9.0), "coat": (-5.0, 1.0, 0.0),
    }),
    (9, "linear", {
        "root_x": 6.0, "pelvis_yaw": -2.0, "chest_yaw": 4.0, "chest_lean": 9.0, "head_yaw": look(-2, 4, 0.85),
        "hand_r": (52.0, 111.0, 12.0), "blade_dir": flat(4), "blade_edge": lead_edge(4),
        "pole_r": (-0.2, -1.0, 0.5), "hand_l": (4.0, 106.0, -28.0), "foot_r": (30.0, 0.0, 9.0),
        "coat": (-8.0, 2.0, 0.0),
    }),
    (12, "out", {
        "root_x": 12.0, "pelvis_h": 86.0, "pelvis_yaw": 8.0, "chest_yaw": 22.0, "chest_lean": 10.0,
        "head_yaw": look(8, 22, 0.8), "hand_r": (38.0, 100.0, -20.0), "blade_dir": flat(-72, 0.1),
        "blade_edge": lead_edge(-72), "pole_r": (-0.4, -1.0, 0.0), "hand_l": (-14.0, 104.0, -30.0),
        "foot_r": (36.0, 0.0, 9.0), "coat": (-10.0, 3.0, -3.0),
    }),
    (20, "inout", {
        "pelvis_h": 88.0, "pelvis_yaw": 6.0, "chest_yaw": 14.0, "head_yaw": look(6, 14, 0.8),
        "hand_r": (26.0, 100.0, -18.0), "blade_dir": flat(-128, 0.25), "blade_edge": (0.0, 1.0, 0.0),
        "hand_l": (-6.0, 100.0, -26.0), "foot_l": (-14.0, 0.0, -9.0), "coat": (-3.0, 0.0, -1.0),
    }),
    (30, "inout", dict(READY, root_x=12.0, hand_r=(36.0, 92.0, 22.0), hand_l=(22.0, 96.0, -20.0),
                       foot_r=(34.0, 0.0, 9.0), foot_l=(-12.0, 0.0, -9.0))),
])

STAND = build_keys([(0, "linear", {
    "pelvis_h": 98.0, "hand_r": (8.0, 84.0, 25.0), "hand_l": (4.0, 84.0, -25.0),
    "blade_dir": (0.95, -0.3, 0.0), "blade_edge": (0.0, -1.0, 0.0),
    "foot_r": (3.0, 0.0, 10.0), "foot_l": (-3.0, 0.0, -10.0), "coat": (0.0, 0.0, 0.0),
})])

MESH_REST = build_keys([(0, "linear", {
    "pelvis_h": 97.0, "hand_r": (14.0, 88.0, 25.0), "hand_l": (2.0, 87.0, -32.0),
    "pole_r": (-0.6, -0.4, 0.8), "pole_l": (-0.6, -0.4, -0.8),
    "blade_dir": (0.941, -0.273, -0.199), "blade_edge": (0.0, -1.0, 0.0),
    "foot_r": (2.0, 0.0, 17.0), "foot_l": (-2.0, 0.0, -18.0), "coat": (0.0, 0.0, 0.0),
})])

CLIPS = {"attack1": (ATTACK1, 30), "stand": (STAND, 1)}
