"""
nav_state_machine.py
====================
Pure-Python finite state machine for the scoutbot waypoint navigator.

No ROS imports. Inputs are plain floats. Outputs are a (linear, angular)
velocity tuple plus the new state name. This means the entire navigation
logic is unit-testable without rclpy, Gazebo, or any real-time clock.

States::

    IDLE            -> nothing to do
    ALIGN_HEADING   -> rotate in place until heading_error is small
    DRIVE           -> drive forward + correct heading simultaneously
    FINE_APPROACH   -> close the last 30 cm with reduced gains, no re-align
    REACHED         -> position is within tolerance; either advance queue
                       or transition to ALIGN_FINAL if waypoint had target_yaw
    ALIGN_FINAL     -> rotate to the waypoint's requested final yaw
    MISSION_DONE    -> queue exhausted; commands are zeroed forever

Hysteresis is built in via asymmetric thresholds (``align_enter`` >
``align_exit`` and ``goal_enter`` > ``goal_tolerance``); this is the
structural fix for the previous project's oscillation issues.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from enum import Enum
from typing import List, Optional, Tuple

from .geometry_utils import (
    Pose2D, heading_error, desired_heading, euclidean_distance, wrap_to_pi,
)
from .pid import PID, PIDConfig


# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------

class NavState(str, Enum):
    IDLE          = "IDLE"
    ALIGN_HEADING = "ALIGN_HEADING"
    DRIVE         = "DRIVE"
    FINE_APPROACH = "FINE_APPROACH"
    ALIGN_FINAL   = "ALIGN_FINAL"
    REACHED       = "REACHED"
    MISSION_DONE  = "MISSION_DONE"


@dataclass(frozen=True)
class WaypointTarget:
    """Plain-data waypoint used by the FSM (decoupled from ROS msg type)."""
    x: float
    y: float
    target_yaw: Optional[float] = None       # None -> skip ALIGN_FINAL
    tolerance: Optional[float] = None        # None -> use default


@dataclass
class NavThresholds:
    align_enter: float
    align_exit: float
    goal_enter: float
    goal_tolerance: float
    final_yaw_tolerance: float
    fine_approach_max_linear: float
    fine_approach_max_angular: float


@dataclass
class NavTick:
    """One tick of FSM output, ready to be packaged as cmd_vel + status."""
    state: NavState
    cmd_linear: float
    cmd_angular: float
    distance_to_goal: float
    heading_error: float
    current_index: int
    total: int


# ---------------------------------------------------------------------------
# State machine
# ---------------------------------------------------------------------------

class NavStateMachine:
    """Drives a list of WaypointTargets to completion.

    The owning ROS node calls :meth:`step` once per control tick with the
    current pose and dt; the SM returns a :class:`NavTick`. The node forwards
    ``(cmd_linear, cmd_angular)`` to ``/scoutbot/cmd_vel`` and the rest of
    the tick fields to ``/scoutbot/nav_status``.
    """

    def __init__(self,
                 waypoints: List[WaypointTarget],
                 thresholds: NavThresholds,
                 linear_pid_cfg: PIDConfig,
                 angular_pid_cfg: PIDConfig) -> None:
        self._waypoints  = list(waypoints)
        self._thresholds = thresholds
        self._index      = 0
        self._state: NavState = (
            NavState.MISSION_DONE if not self._waypoints else NavState.IDLE
        )

        # Two PIDs. Distinct configs (linear/angular) -> separate instances.
        self._pid_lin = PID(linear_pid_cfg)
        self._pid_ang = PID(angular_pid_cfg)

        # Cached fine-approach configs derived from main configs but with
        # tighter output ceilings. Avoids re-allocating on every tick.
        self._fine_lin_cfg = PIDConfig(
            kp=linear_pid_cfg.kp, ki=linear_pid_cfg.ki, kd=linear_pid_cfg.kd,
            output_min=linear_pid_cfg.output_min,
            output_max=thresholds.fine_approach_max_linear,
            integral_clamp=linear_pid_cfg.integral_clamp,
            deadband=linear_pid_cfg.deadband,
        )
        self._fine_ang_cfg = PIDConfig(
            kp=angular_pid_cfg.kp, ki=angular_pid_cfg.ki, kd=angular_pid_cfg.kd,
            output_min=-thresholds.fine_approach_max_angular,
            output_max= thresholds.fine_approach_max_angular,
            integral_clamp=angular_pid_cfg.integral_clamp,
            deadband=angular_pid_cfg.deadband,
        )

    # ------------------------------------------------------------------
    # Public read-only accessors (handy for diagnostic node)
    # ------------------------------------------------------------------
    @property
    def state(self) -> NavState:
        return self._state

    @property
    def current_index(self) -> int:
        return self._index if self._index < len(self._waypoints) else -1

    @property
    def total(self) -> int:
        return len(self._waypoints)

    @property
    def is_done(self) -> bool:
        return self._state == NavState.MISSION_DONE

    # ------------------------------------------------------------------
    # Main entry point
    # ------------------------------------------------------------------
    def step(self, pose: Pose2D, dt: float) -> NavTick:
        """Advance the FSM one tick.

        Parameters
        ----------
        pose : (x, y, yaw)
            Current robot pose in the same frame as the waypoints.
        dt : float
            Seconds since the last :meth:`step` call. Must be > 0.

        Returns
        -------
        NavTick
            ``(state, cmd_linear, cmd_angular, distance, heading_error,
              current_index, total)``.
        """
        # Mission-already-done short-circuit -- guarantees zero output forever.
        if self._state == NavState.MISSION_DONE:
            return NavTick(NavState.MISSION_DONE, 0.0, 0.0, 0.0, 0.0,
                           -1, len(self._waypoints))

        # Lazy first-tick transition: IDLE -> ALIGN_HEADING.
        if self._state == NavState.IDLE:
            self._enter(NavState.ALIGN_HEADING)

        wp = self._waypoints[self._index]
        cx, cy, cyaw = pose
        dist = euclidean_distance(cx, cy, wp.x, wp.y)
        head_err = heading_error(cyaw, desired_heading(cx, cy, wp.x, wp.y))
        tol = wp.tolerance if (wp.tolerance and wp.tolerance > 0.0) \
                            else self._thresholds.goal_tolerance

        # ---- transition logic (priority order matters) -------------------
        if self._state == NavState.ALIGN_HEADING:
            if abs(head_err) <= self._thresholds.align_exit:
                self._enter(NavState.DRIVE)

        elif self._state == NavState.DRIVE:
            if dist <= self._thresholds.goal_enter:
                self._enter(NavState.FINE_APPROACH)
            elif abs(head_err) >= self._thresholds.align_enter:
                # Lost too much heading -> stop, re-align, resume.
                self._enter(NavState.ALIGN_HEADING)

        elif self._state == NavState.FINE_APPROACH:
            if dist <= tol:
                self._enter(NavState.REACHED)

        elif self._state == NavState.REACHED:
            if wp.target_yaw is not None:
                self._enter(NavState.ALIGN_FINAL)
            else:
                self._advance_queue()

        elif self._state == NavState.ALIGN_FINAL:
            yaw_err = wrap_to_pi((wp.target_yaw or 0.0) - cyaw)
            if abs(yaw_err) <= self._thresholds.final_yaw_tolerance:
                self._advance_queue()

        # After potential queue advance the state may now be MISSION_DONE.
        if self._state == NavState.MISSION_DONE:
            return NavTick(NavState.MISSION_DONE, 0.0, 0.0, dist, head_err,
                           -1, len(self._waypoints))

        # ---- output computation (depends on the *current* state) --------
        v, w = self._compute_command(dist, head_err, cyaw, wp, dt)
        return NavTick(self._state, v, w, dist, head_err,
                       self._index, len(self._waypoints))

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------
    def _enter(self, new_state: NavState) -> None:
        """Transition + reset both PIDs (kills any windup from the prior state)."""
        self._state = new_state
        self._pid_lin.reset()
        self._pid_ang.reset()

    def _advance_queue(self) -> None:
        self._index += 1
        if self._index >= len(self._waypoints):
            self._enter(NavState.MISSION_DONE)
        else:
            self._enter(NavState.ALIGN_HEADING)

    def _compute_command(self,
                         dist: float,
                         head_err: float,
                         cyaw: float,
                         wp: WaypointTarget,
                         dt: float) -> Tuple[float, float]:
        """Return ``(v, w)`` for the *current* state."""
        s = self._state

        if s == NavState.ALIGN_HEADING:
            w = self._pid_ang.update(error=head_err, dt=dt, measurement=cyaw)
            return 0.0, w

        if s == NavState.DRIVE:
            # Forward speed proportional to distance, attenuated by mis-alignment.
            v_raw = self._pid_lin.update(error=dist, dt=dt, measurement=-dist)
            # cos(head_err) goes to 0 at +/- pi/2, negative beyond -> we clip
            # the negative half so the robot never reverses unintentionally.
            v = v_raw * max(0.0, math.cos(head_err))
            w = self._pid_ang.update(error=head_err, dt=dt, measurement=cyaw)
            return v, w

        if s == NavState.FINE_APPROACH:
            # Use the gentler fine-approach configs by swapping cfg in place.
            self._pid_lin.cfg = self._fine_lin_cfg
            self._pid_ang.cfg = self._fine_ang_cfg
            v_raw = self._pid_lin.update(error=dist, dt=dt, measurement=-dist)
            v = v_raw * max(0.0, math.cos(head_err))
            w = self._pid_ang.update(error=head_err, dt=dt, measurement=cyaw)
            return v, w

        if s == NavState.ALIGN_FINAL:
            yaw_err = wrap_to_pi((wp.target_yaw or 0.0) - cyaw)
            w = self._pid_ang.update(error=yaw_err, dt=dt, measurement=cyaw)
            return 0.0, w

        # IDLE / REACHED: zero output until next tick rolls the FSM forward.
        return 0.0, 0.0
