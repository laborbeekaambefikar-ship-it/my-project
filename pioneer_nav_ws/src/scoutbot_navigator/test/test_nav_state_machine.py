"""
Unit tests for nav_state_machine + geometry_utils + pid.

Run inside the workspace::

    colcon test --packages-select scoutbot_navigator
    colcon test-result --verbose

Or directly without colcon (pure-python, no ROS deps)::

    cd src/scoutbot_navigator
    python3 -m pytest test/test_nav_state_machine.py -v
"""

from __future__ import annotations

import math
import os
import sys
import unittest

# Allow running standalone (without `colcon test` adding the package to sys.path)
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from scoutbot_navigator.geometry_utils import (  # noqa: E402
    wrap_to_pi, euclidean_distance, desired_heading,
    heading_error, quaternion_to_yaw,
)
from scoutbot_navigator.pid import PID, PIDConfig  # noqa: E402
from scoutbot_navigator.nav_state_machine import (  # noqa: E402
    NavStateMachine, NavThresholds, NavState, WaypointTarget,
)


# ---------------------------------------------------------------------------
# geometry_utils
# ---------------------------------------------------------------------------

class TestGeometry(unittest.TestCase):

    def test_wrap_to_pi_basic(self):
        self.assertAlmostEqual(wrap_to_pi(0.0), 0.0)
        self.assertAlmostEqual(wrap_to_pi(math.pi), math.pi)
        # both +pi and -pi must collapse to +pi (half-open interval)
        self.assertAlmostEqual(wrap_to_pi(-math.pi), math.pi)

    def test_wrap_to_pi_far_negative(self):
        # -3pi/2 -> +pi/2 (rotate the short way)
        self.assertAlmostEqual(wrap_to_pi(-3 * math.pi / 2), math.pi / 2, places=6)

    def test_wrap_to_pi_far_positive(self):
        self.assertAlmostEqual(wrap_to_pi(3 * math.pi / 2), -math.pi / 2, places=6)

    def test_heading_error_short_path(self):
        # facing 170 deg, want 190 deg (= -170 deg) -> short rotation = +20 deg
        cyaw = math.radians(170)
        tyaw = math.radians(-170)
        err = heading_error(cyaw, tyaw)
        self.assertAlmostEqual(err, math.radians(20), places=4)

    def test_quaternion_to_yaw_zero(self):
        self.assertAlmostEqual(quaternion_to_yaw(0, 0, 0, 1), 0.0, places=6)

    def test_quaternion_to_yaw_90(self):
        # 90deg yaw quaternion: (0, 0, sin(45), cos(45))
        q = (0.0, 0.0, math.sin(math.pi/4), math.cos(math.pi/4))
        self.assertAlmostEqual(quaternion_to_yaw(*q), math.pi / 2, places=6)

    def test_distance(self):
        self.assertAlmostEqual(euclidean_distance(0, 0, 3, 4), 5.0)

    def test_desired_heading(self):
        self.assertAlmostEqual(desired_heading(0, 0, 1, 1), math.pi / 4)


# ---------------------------------------------------------------------------
# PID
# ---------------------------------------------------------------------------

class TestPID(unittest.TestCase):

    def _cfg(self, **overrides) -> PIDConfig:
        base = dict(kp=1.0, ki=0.0, kd=0.0,
                    output_min=-1.0, output_max=1.0,
                    integral_clamp=1.0, deadband=0.0)
        base.update(overrides)
        return PIDConfig(**base)

    def test_proportional_only(self):
        pid = PID(self._cfg(kp=2.0))
        self.assertAlmostEqual(pid.update(0.3, 0.02), 0.6)

    def test_saturation_high(self):
        pid = PID(self._cfg(kp=10.0))
        self.assertAlmostEqual(pid.update(0.5, 0.02), 1.0)  # 5.0 saturates at 1.0

    def test_saturation_low(self):
        pid = PID(self._cfg(kp=10.0, output_min=0.0))
        self.assertAlmostEqual(pid.update(-0.3, 0.02), 0.0)  # negative clipped

    def test_deadband(self):
        pid = PID(self._cfg(kp=1.0, deadband=0.5))
        self.assertAlmostEqual(pid.update(0.2, 0.02), 0.0)   # below deadband -> 0
        self.assertAlmostEqual(pid.update(0.7, 0.02), 0.7)

    def test_reset_clears_integral(self):
        pid = PID(self._cfg(kp=0.0, ki=1.0))
        for _ in range(10):
            pid.update(0.1, 0.1)
        self.assertGreater(pid.last_output, 0.05)
        pid.reset()
        self.assertEqual(pid.last_output, 0.0)


# ---------------------------------------------------------------------------
# State machine
# ---------------------------------------------------------------------------

class TestStateMachine(unittest.TestCase):

    def _make_sm(self, waypoints) -> NavStateMachine:
        thresholds = NavThresholds(
            align_enter=0.40, align_exit=0.05,
            goal_enter=0.30, goal_tolerance=0.05,
            final_yaw_tolerance=0.05,
            fine_approach_max_linear=0.20,
            fine_approach_max_angular=0.80,
        )
        lin = PIDConfig(kp=0.8, ki=0.0, kd=0.0,
                        output_min=0.0, output_max=1.0,
                        integral_clamp=0.5, deadband=0.0)
        ang = PIDConfig(kp=1.5, ki=0.0, kd=0.0,
                        output_min=-2.0, output_max=2.0,
                        integral_clamp=0.5, deadband=0.0)
        return NavStateMachine(waypoints, thresholds, lin, ang)

    # ------------------------- empty queue --------------------------------
    def test_empty_queue_immediately_done(self):
        sm = self._make_sm([])
        tick = sm.step((0.0, 0.0, 0.0), 0.02)
        self.assertEqual(tick.state, NavState.MISSION_DONE)
        self.assertEqual(tick.cmd_linear, 0.0)
        self.assertEqual(tick.cmd_angular, 0.0)

    # ------------------------- aligns first -------------------------------
    def test_first_tick_enters_align_when_misaligned(self):
        sm = self._make_sm([WaypointTarget(x=1.0, y=1.0)])
        # facing +X but goal is at +45 deg -> heading_error ~ +45 deg
        tick = sm.step((0.0, 0.0, 0.0), 0.02)
        self.assertEqual(tick.state, NavState.ALIGN_HEADING)
        self.assertEqual(tick.cmd_linear, 0.0)
        self.assertGreater(tick.cmd_angular, 0.0)  # rotate CCW toward +45

    def test_drives_when_aligned(self):
        sm = self._make_sm([WaypointTarget(x=1.0, y=0.0)])
        # facing +X, goal at +X -> heading_error ~ 0
        tick = sm.step((0.0, 0.0, 0.0), 0.02)
        self.assertEqual(tick.state, NavState.DRIVE)
        self.assertGreater(tick.cmd_linear, 0.0)

    # ------------------------- hysteresis ---------------------------------
    def test_realign_hysteresis(self):
        sm = self._make_sm([WaypointTarget(x=10.0, y=0.0)])
        # tick 1: aligned, in DRIVE
        sm.step((0.0, 0.0, 0.0), 0.02)
        self.assertEqual(sm.state, NavState.DRIVE)
        # Inject a 30 deg yaw drift -- below align_enter 0.40 rad ~ 22.9 deg?
        # 30 deg = 0.524 rad -> SHOULD trigger realign.
        sm.step((0.5, 0.0, math.radians(30)), 0.02)
        self.assertEqual(sm.state, NavState.ALIGN_HEADING)

    def test_no_realign_below_threshold(self):
        sm = self._make_sm([WaypointTarget(x=10.0, y=0.0)])
        sm.step((0.0, 0.0, 0.0), 0.02)
        # 10 deg = 0.175 rad < align_enter 0.40 -> stay in DRIVE
        sm.step((0.5, 0.0, math.radians(10)), 0.02)
        self.assertEqual(sm.state, NavState.DRIVE)

    # ------------------------- multi-waypoint progression ----------------
    def test_advance_waypoint(self):
        sm = self._make_sm([
            WaypointTarget(x=0.0, y=0.0),       # already at it
            WaypointTarget(x=1.0, y=0.0),
        ])
        tick = sm.step((0.0, 0.0, 0.0), 0.02)
        # Within tolerance of (0,0): IDLE->ALIGN_HEADING (0 err) -> DRIVE on
        # next tick? Actually with d=0 it skips through to FINE_APPROACH then
        # REACHED on subsequent ticks. We just assert that, after a few ticks,
        # the FSM has advanced past index 0.
        for _ in range(20):
            tick = sm.step((0.0, 0.0, 0.0), 0.02)
        self.assertGreaterEqual(sm.current_index, 1)
        self.assertNotEqual(tick.state, NavState.MISSION_DONE)

    def test_mission_done_after_all_waypoints(self):
        sm = self._make_sm([WaypointTarget(x=0.0, y=0.0)])
        for _ in range(50):
            sm.step((0.0, 0.0, 0.0), 0.02)
        self.assertTrue(sm.is_done)
        # Subsequent ticks must still output zero, never raise.
        tick = sm.step((10.0, 10.0, 0.0), 0.02)
        self.assertEqual(tick.cmd_linear, 0.0)
        self.assertEqual(tick.cmd_angular, 0.0)

    # ------------------------- final-yaw alignment -----------------------
    def test_align_final_runs_when_target_yaw_set(self):
        sm = self._make_sm([
            WaypointTarget(x=0.0, y=0.0, target_yaw=math.pi/2),
        ])
        # robot already at goal but facing wrong way
        for _ in range(5):
            sm.step((0.0, 0.0, 0.0), 0.02)
        # Should be in ALIGN_FINAL or have already finished it.
        self.assertIn(sm.state, (NavState.ALIGN_FINAL, NavState.MISSION_DONE))


if __name__ == '__main__':
    unittest.main()
