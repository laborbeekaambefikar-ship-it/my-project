"""
geometry_utils.py
=================
Pure-Python (no ROS) geometric helpers. Kept free of rclpy so the state
machine and these utilities are unit-testable in isolation -- a structural
fix for the previous project's "poor navigation logic" failure mode.

All angles are in radians. Conventions:
* yaw 0 == +X axis
* positive yaw == counter-clockwise
* wrap range == (-pi, pi]
"""

from __future__ import annotations

import math
from typing import Tuple


# ---------------------------------------------------------------------------
# Angle helpers
# ---------------------------------------------------------------------------

def wrap_to_pi(angle: float) -> float:
    """Wrap any real angle into (-pi, pi].

    The naive ``math.atan2`` already returns a value in (-pi, pi], but a
    DIFFERENCE of two atan2 outputs is in (-2*pi, 2*pi) and must be re-wrapped
    before being fed into a PID, otherwise a controller asked to rotate by
    +5 deg can spin -355 deg instead. This was the root cause of the
    previous project's "incorrect angular velocity" failure.

    >>> wrap_to_pi(0.0)
    0.0
    >>> abs(wrap_to_pi(math.pi)      - math.pi)      < 1e-9
    True
    >>> abs(wrap_to_pi(-math.pi)     - math.pi)      < 1e-9
    True
    >>> abs(wrap_to_pi( 3*math.pi/2) - (-math.pi/2)) < 1e-9
    True
    >>> abs(wrap_to_pi(-3*math.pi/2) - ( math.pi/2)) < 1e-9
    True
    """
    # math.remainder gives result in (-pi, pi] for divisor 2*pi -- exactly
    # the behaviour we want. It is more numerically robust than the
    # fmod-and-conditional pattern used in many ROS tutorials.
    wrapped = math.remainder(angle, math.tau)  # math.tau == 2*pi
    # math.remainder returns [-pi, pi]; collapse the lower edge to keep the
    # interval half-open so unit tests can rely on a unique representative.
    if wrapped <= -math.pi:
        wrapped += math.tau
    return wrapped


# ---------------------------------------------------------------------------
# 2-D pose primitives
# ---------------------------------------------------------------------------

def euclidean_distance(x1: float, y1: float, x2: float, y2: float) -> float:
    """Plane distance between two points. Branchless, no sqrt-of-zero edge cases."""
    return math.hypot(x2 - x1, y2 - y1)


def desired_heading(from_x: float, from_y: float,
                    to_x: float,   to_y: float) -> float:
    """Bearing FROM point 1 TO point 2, measured in (-pi, pi] from the +X axis.

    Returns 0.0 when the two points coincide -- callers should already gate
    on ``euclidean_distance < tolerance`` before consulting this value.
    """
    dx = to_x - from_x
    dy = to_y - from_y
    if dx == 0.0 and dy == 0.0:
        return 0.0
    return math.atan2(dy, dx)


def heading_error(current_yaw: float, target_yaw: float) -> float:
    """Smallest signed rotation that takes ``current_yaw`` to ``target_yaw``.

    Output is wrapped to (-pi, pi] so a heading PID can drive it to zero
    without spinning the long way around.
    """
    return wrap_to_pi(target_yaw - current_yaw)


# ---------------------------------------------------------------------------
# Quaternion -> yaw  (avoids depending on tf_transformations from pure Python)
# ---------------------------------------------------------------------------

def quaternion_to_yaw(qx: float, qy: float, qz: float, qw: float) -> float:
    """Extract yaw from a unit quaternion (x, y, z, w).

    Standard ZYX-Tait-Bryan formula, matching ``tf2`` and
    ``tf_transformations.euler_from_quaternion``. Returns yaw in (-pi, pi].
    """
    # yaw (Z) from ZYX convention:
    siny_cosp = 2.0 * (qw * qz + qx * qy)
    cosy_cosp = 1.0 - 2.0 * (qy * qy + qz * qz)
    return math.atan2(siny_cosp, cosy_cosp)


# ---------------------------------------------------------------------------
# Convenience tuple helpers
# ---------------------------------------------------------------------------

Pose2D = Tuple[float, float, float]   # (x, y, yaw)


def pose_difference(current: Pose2D, target_xy: Tuple[float, float]
                    ) -> Tuple[float, float]:
    """Return ``(distance, heading_error)`` from ``current`` to ``target_xy``.

    A single canonical entry point used by the state machine each tick.
    """
    cx, cy, cyaw = current
    tx, ty = target_xy
    dist = euclidean_distance(cx, cy, tx, ty)
    head = heading_error(cyaw, desired_heading(cx, cy, tx, ty))
    return dist, head
