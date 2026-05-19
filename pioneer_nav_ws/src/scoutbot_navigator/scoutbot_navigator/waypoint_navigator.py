"""
waypoint_navigator.py
=====================
Thin rclpy wrapper around the pure-Python NavStateMachine.

Subscribes
----------
* ``/scoutbot/odom``                  (nav_msgs/Odometry)

Publishes
---------
* ``/scoutbot/cmd_vel``               (geometry_msgs/Twist)         50 Hz
* ``/scoutbot/nav_status``            (scoutbot_interfaces/NavigationStatus) 2 Hz

Parameters
----------
All parameters listed in pid_gains.yaml under ``waypoint_navigator:`` are
declared with sensible defaults so the node can also start with no YAML.

Waypoints can be loaded one of two ways (mutually exclusive, checked in order):

1. ``waypoints_yaml`` parameter -> path to a YAML file shaped like::

       waypoints:
         - {x: 1.0, y: 0.0}
         - {x: 1.0, y: 1.0, target_yaw: 1.5708}
         - {x: 0.0, y: 1.0, tolerance: 0.10}

2. Inline parameters ``waypoints_x``, ``waypoints_y``, ``waypoints_yaw``
   (any value > 1e6 in waypoints_yaw means "no final yaw").

If neither is supplied the node logs a warning and immediately enters
MISSION_DONE -- it stays alive so a higher-level orchestrator can publish
new waypoints later via service / topic (future work, not this PR).
"""

from __future__ import annotations

import math
from typing import List, Optional

import rclpy
from rclpy.duration import Duration
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy

from geometry_msgs.msg import Twist
from nav_msgs.msg import Odometry
from std_msgs.msg import Header

from scoutbot_interfaces.msg import NavigationStatus

from .geometry_utils import quaternion_to_yaw
from .nav_state_machine import (
    NavStateMachine, NavThresholds, NavState, WaypointTarget,
)
from .pid import PIDConfig


# ---------------------------------------------------------------------------
# Helpers (kept module-level, easy to unit-test in isolation)
# ---------------------------------------------------------------------------

def _load_waypoints_from_yaml(path: str) -> List[WaypointTarget]:
    """Load a list of WaypointTargets from a YAML file. Raises on bad shape."""
    import yaml  # imported lazily to keep cold-start fast
    with open(path, 'r') as fh:
        data = yaml.safe_load(fh) or {}
    items = data.get('waypoints', [])
    out: List[WaypointTarget] = []
    for i, raw in enumerate(items):
        if not isinstance(raw, dict) or 'x' not in raw or 'y' not in raw:
            raise ValueError(
                f'Waypoint #{i} in {path} must be a mapping with x and y keys; got {raw!r}'
            )
        out.append(WaypointTarget(
            x=float(raw['x']),
            y=float(raw['y']),
            target_yaw=(float(raw['target_yaw']) if 'target_yaw' in raw else None),
            tolerance=(float(raw['tolerance']) if 'tolerance' in raw else None),
        ))
    return out


def _load_waypoints_from_lists(xs: List[float],
                               ys: List[float],
                               yaws: List[float]) -> List[WaypointTarget]:
    """Zip three parallel lists. ``yaws[i] > 1e6`` means "no final yaw"."""
    if len(xs) != len(ys):
        raise ValueError(f'waypoints_x ({len(xs)}) and waypoints_y ({len(ys)}) lengths differ')
    if yaws and len(yaws) != len(xs):
        raise ValueError(f'waypoints_yaw ({len(yaws)}) length must match waypoints_x ({len(xs)})')
    out: List[WaypointTarget] = []
    for i, (x, y) in enumerate(zip(xs, ys)):
        ty: Optional[float] = None
        if yaws and yaws[i] < 1e6:
            ty = float(yaws[i])
        out.append(WaypointTarget(x=float(x), y=float(y), target_yaw=ty))
    return out


# ---------------------------------------------------------------------------
# The node
# ---------------------------------------------------------------------------

class WaypointNavigatorNode(Node):
    """The single rclpy node that drives the scoutbot through its waypoints."""

    def __init__(self) -> None:
        super().__init__('waypoint_navigator')

        # ---- declare every parameter (defaults match pid_gains.yaml) ----
        # Topics / frames
        self.declare_parameter('odom_topic',    '/scoutbot/odom')
        self.declare_parameter('cmd_vel_topic', '/scoutbot/cmd_vel')
        self.declare_parameter('status_topic',  '/scoutbot/nav_status')
        self.declare_parameter('odom_frame',    'scout_odom')

        # Timing
        self.declare_parameter('control_frequency_hz', 50.0)
        self.declare_parameter('status_publish_hz',     2.0)

        # Linear PID
        self.declare_parameter('linear_kp', 0.8)
        self.declare_parameter('linear_ki', 0.0)
        self.declare_parameter('linear_kd', 0.05)
        self.declare_parameter('linear_max_output',    1.0)
        self.declare_parameter('linear_min_output',    0.0)
        self.declare_parameter('linear_integral_clamp', 0.5)
        self.declare_parameter('linear_deadband',      0.01)

        # Angular PID
        self.declare_parameter('angular_kp', 1.5)
        self.declare_parameter('angular_ki', 0.0)
        self.declare_parameter('angular_kd', 0.10)
        self.declare_parameter('angular_max_output',    2.0)
        self.declare_parameter('angular_min_output',   -2.0)
        self.declare_parameter('angular_integral_clamp', 0.8)
        self.declare_parameter('angular_deadband',      0.02)

        # State-machine thresholds
        self.declare_parameter('align_enter_threshold', 0.40)
        self.declare_parameter('align_exit_threshold',  0.05)
        self.declare_parameter('goal_enter_threshold',  0.30)
        self.declare_parameter('goal_tolerance',        0.05)
        self.declare_parameter('final_yaw_tolerance',   0.05)
        self.declare_parameter('fine_approach_max_linear',  0.20)
        self.declare_parameter('fine_approach_max_angular', 0.80)

        # Safety
        self.declare_parameter('odom_stale_timeout', 1.0)

        # Waypoint sources
        self.declare_parameter('waypoints_yaml', '')
        self.declare_parameter('waypoints_x',   [0.0])
        self.declare_parameter('waypoints_y',   [0.0])
        self.declare_parameter('waypoints_yaw', [1.0e9])  # 1e9 -> "no final yaw"

        # ---- read parameters into local convenience vars ----------------
        self._odom_topic    = self.get_parameter('odom_topic').value
        self._cmd_vel_topic = self.get_parameter('cmd_vel_topic').value
        self._status_topic  = self.get_parameter('status_topic').value
        self._odom_frame    = self.get_parameter('odom_frame').value
        ctrl_hz             = float(self.get_parameter('control_frequency_hz').value)
        status_hz           = float(self.get_parameter('status_publish_hz').value)
        self._odom_stale    = float(self.get_parameter('odom_stale_timeout').value)

        thresholds = NavThresholds(
            align_enter        = float(self.get_parameter('align_enter_threshold').value),
            align_exit         = float(self.get_parameter('align_exit_threshold').value),
            goal_enter         = float(self.get_parameter('goal_enter_threshold').value),
            goal_tolerance     = float(self.get_parameter('goal_tolerance').value),
            final_yaw_tolerance= float(self.get_parameter('final_yaw_tolerance').value),
            fine_approach_max_linear  = float(self.get_parameter('fine_approach_max_linear').value),
            fine_approach_max_angular = float(self.get_parameter('fine_approach_max_angular').value),
        )

        lin_cfg = PIDConfig(
            kp=float(self.get_parameter('linear_kp').value),
            ki=float(self.get_parameter('linear_ki').value),
            kd=float(self.get_parameter('linear_kd').value),
            output_min=float(self.get_parameter('linear_min_output').value),
            output_max=float(self.get_parameter('linear_max_output').value),
            integral_clamp=float(self.get_parameter('linear_integral_clamp').value),
            deadband=float(self.get_parameter('linear_deadband').value),
        )
        ang_cfg = PIDConfig(
            kp=float(self.get_parameter('angular_kp').value),
            ki=float(self.get_parameter('angular_ki').value),
            kd=float(self.get_parameter('angular_kd').value),
            output_min=float(self.get_parameter('angular_min_output').value),
            output_max=float(self.get_parameter('angular_max_output').value),
            integral_clamp=float(self.get_parameter('angular_integral_clamp').value),
            deadband=float(self.get_parameter('angular_deadband').value),
        )

        # ---- load waypoints ---------------------------------------------
        waypoints = self._load_waypoints()
        if not waypoints:
            self.get_logger().warn(
                'No waypoints supplied (set ~waypoints_yaml or '
                '~waypoints_x/~waypoints_y). Navigator will idle.'
            )
        else:
            self.get_logger().info(f'Loaded {len(waypoints)} waypoint(s).')

        self._sm = NavStateMachine(
            waypoints=waypoints,
            thresholds=thresholds,
            linear_pid_cfg=lin_cfg,
            angular_pid_cfg=ang_cfg,
        )

        # ---- ROS interfaces ---------------------------------------------
        # Best-effort odom QoS matches diff_drive_controller's default publisher.
        odom_qos = QoSProfile(
            reliability=ReliabilityPolicy.RELIABLE,
            history=HistoryPolicy.KEEP_LAST,
            depth=10,
        )
        self._sub_odom = self.create_subscription(
            Odometry, self._odom_topic, self._on_odom, odom_qos
        )
        self._pub_cmd = self.create_publisher(Twist, self._cmd_vel_topic, 10)
        self._pub_status = self.create_publisher(
            NavigationStatus, self._status_topic, 10
        )

        # ---- runtime state ----------------------------------------------
        self._latest_odom: Optional[Odometry] = None
        self._latest_odom_time = self.get_clock().now()
        self._last_tick_time   = self.get_clock().now()
        self._last_cmd: Twist  = Twist()

        # ---- timers ------------------------------------------------------
        self._control_timer = self.create_timer(
            1.0 / ctrl_hz, self._on_control_tick
        )
        self._status_timer = self.create_timer(
            1.0 / status_hz, self._on_status_tick
        )

        self.get_logger().info(
            f'waypoint_navigator ready. control={ctrl_hz}Hz status={status_hz}Hz '
            f'odom={self._odom_topic} cmd_vel={self._cmd_vel_topic}'
        )

    # ------------------------------------------------------------------
    # Waypoint loading
    # ------------------------------------------------------------------
    def _load_waypoints(self) -> List[WaypointTarget]:
        yaml_path = (self.get_parameter('waypoints_yaml').value or '').strip()
        if yaml_path:
            try:
                return _load_waypoints_from_yaml(yaml_path)
            except Exception as exc:  # noqa: BLE001 -- we want to log and continue
                self.get_logger().error(
                    f'Failed to load waypoints from {yaml_path}: {exc}'
                )
                return []

        xs   = list(self.get_parameter('waypoints_x').value or [])
        ys   = list(self.get_parameter('waypoints_y').value or [])
        yaws = list(self.get_parameter('waypoints_yaw').value or [])

        # The default is [0.0] for x and y, and [1e9] for yaw -- treat that
        # exact triple as "user did not configure waypoints".
        is_default = (xs == [0.0] and ys == [0.0] and yaws == [1.0e9])
        if is_default or len(xs) == 0:
            return []

        try:
            return _load_waypoints_from_lists(xs, ys, yaws)
        except Exception as exc:  # noqa: BLE001
            self.get_logger().error(f'Bad waypoints_*: {exc}')
            return []

    # ------------------------------------------------------------------
    # Subscriber callback
    # ------------------------------------------------------------------
    def _on_odom(self, msg: Odometry) -> None:
        self._latest_odom = msg
        self._latest_odom_time = self.get_clock().now()

    # ------------------------------------------------------------------
    # 50 Hz control tick -- the heartbeat of the navigator
    # ------------------------------------------------------------------
    def _on_control_tick(self) -> None:
        now = self.get_clock().now()
        dt = (now - self._last_tick_time).nanoseconds * 1e-9
        self._last_tick_time = now
        if dt <= 0.0:
            dt = 1e-3  # first tick guard

        # Safety: stop if odom is stale or never received.
        if self._latest_odom is None:
            self._publish_zero_cmd()
            self.get_logger().warn(
                'Waiting for first odometry message...',
                throttle_duration_sec=2.0,
            )
            return

        odom_age = (now - self._latest_odom_time).nanoseconds * 1e-9
        if odom_age > self._odom_stale:
            self._publish_zero_cmd()
            self.get_logger().error(
                f'Odom stale ({odom_age:.2f}s) -- emergency stop.',
                throttle_duration_sec=1.0,
            )
            return

        # Mission complete -> latch zero forever, no more PID work.
        if self._sm.is_done:
            self._publish_zero_cmd()
            return

        # Extract pose from odometry.
        p = self._latest_odom.pose.pose
        yaw = quaternion_to_yaw(
            p.orientation.x, p.orientation.y, p.orientation.z, p.orientation.w,
        )

        tick = self._sm.step((p.position.x, p.position.y, yaw), dt)

        # ---- publish command --------------------------------------------
        cmd = Twist()
        cmd.linear.x  = tick.cmd_linear
        cmd.angular.z = tick.cmd_angular
        self._pub_cmd.publish(cmd)
        self._last_cmd = cmd

        # ---- throttled human-readable log -------------------------------
        self.get_logger().info(
            f'[{tick.state.value}] wp {tick.current_index+1}/{tick.total} '
            f'd={tick.distance_to_goal:.2f}m '
            f'he={math.degrees(tick.heading_error):+5.1f}deg '
            f'v={tick.cmd_linear:+.2f} w={tick.cmd_angular:+.2f}',
            throttle_duration_sec=1.0,
        )

    # ------------------------------------------------------------------
    # 2 Hz diagnostic publish
    # ------------------------------------------------------------------
    def _on_status_tick(self) -> None:
        msg = NavigationStatus()
        msg.header = Header()
        msg.header.stamp = self.get_clock().now().to_msg()
        msg.header.frame_id = self._odom_frame

        if self._latest_odom is not None:
            p = self._latest_odom.pose.pose
            yaw = quaternion_to_yaw(
                p.orientation.x, p.orientation.y, p.orientation.z, p.orientation.w,
            )
            # Run a "view-only" computation: we do NOT step the FSM here, we
            # just report the last commanded values + recompute distance/error
            # vs the active waypoint for live monitoring.
            from .geometry_utils import euclidean_distance, heading_error, desired_heading
            if 0 <= self._sm.current_index < self._sm.total:
                wpx = wpy = 0.0  # populated below
                # Re-acquire the active waypoint via internal accessor.
                wp = self._sm._waypoints[self._sm.current_index]  # noqa: SLF001
                wpx, wpy = wp.x, wp.y
                msg.distance_to_goal = euclidean_distance(
                    p.position.x, p.position.y, wpx, wpy)
                msg.heading_error = heading_error(
                    yaw, desired_heading(p.position.x, p.position.y, wpx, wpy))
            else:
                msg.distance_to_goal = 0.0
                msg.heading_error = 0.0

        msg.state = self._sm.state.value
        msg.current_waypoint_index = self._sm.current_index
        msg.total_waypoints = self._sm.total
        msg.cmd_linear_velocity  = self._last_cmd.linear.x
        msg.cmd_angular_velocity = self._last_cmd.angular.z
        msg.is_active = self._sm.state not in (
            NavState.IDLE, NavState.MISSION_DONE, NavState.REACHED,
        )
        self._pub_status.publish(msg)

    # ------------------------------------------------------------------
    # Utilities
    # ------------------------------------------------------------------
    def _publish_zero_cmd(self) -> None:
        z = Twist()
        self._pub_cmd.publish(z)
        self._last_cmd = z


# ---------------------------------------------------------------------------
# Entry point  (referenced by setup.py console_scripts)
# ---------------------------------------------------------------------------

def main(args=None) -> None:
    rclpy.init(args=args)
    node = WaypointNavigatorNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        # Final stop for safety.
        try:
            node._publish_zero_cmd()  # noqa: SLF001 -- shutdown safety
        except Exception:  # noqa: BLE001
            pass
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
