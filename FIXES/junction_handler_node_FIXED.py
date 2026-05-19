#!/usr/bin/env python3
"""
Junction Handler Node — FIXED VERSION
--------------------------------------
FIXES APPLIED:
  1. Uses OPTICAL SENSOR junction detection (5+ sensors = junction)
     instead of relying solely on X-coordinate matching
  2. Widened the Y-tolerance from 0.30 to 0.60 (AGV oscillation)
  3. Widened the X-tolerance from 0.15 to 0.40 (more forgiving)
  4. Turn is now SENSOR-GUIDED: drives while turning until the
     line follower sensors re-detect a line (instead of blind timer)
  5. Added massive debug logging so you can SEE what's happening
  6. Added a secondary trigger: if optical sensors detect a junction
     while in GOING state, that's also a valid trigger

WHAT THIS NODE DOES:
  When the AGV is in GOING state and reaches the correct spur, this node:
  1. Disables the line follower
  2. Steers the AGV left (into the spur)
  3. Once the line follower's sensors detect the spur line, stops turning
  4. Re-enables the line follower (which now follows the spur)

  When RETURNING: same logic but turns back onto the main aisle.
"""

import math
import rclpy
from rclpy.node import Node

from nav_msgs.msg import Odometry
from std_msgs.msg import Bool, Float32MultiArray
from geometry_msgs.msg import Twist

from agv_msgs.msg import AGVState

# Import shelf map to get target aisle X coordinates
try:
    from agv_control.shelf_map import SHELF_MAP
except ImportError:
    SHELF_MAP = {}


def yaw_from_quat(q):
    siny_cosp = 2.0 * (q.w * q.z + q.x * q.y)
    cosy_cosp = 1.0 - 2.0 * (q.y * q.y + q.z * q.z)
    return math.atan2(siny_cosp, cosy_cosp)


class JunctionHandlerNode(Node):

    def __init__(self):
        super().__init__('junction_handler_node')

        # --- Parameters ---
        self.declare_parameter('x_tolerance', 0.40)      # meters (WAS 0.15)
        self.declare_parameter('y_tolerance', 0.60)      # meters (WAS 0.30)
        self.declare_parameter('turn_speed', 0.50)       # rad/s (WAS 0.60)
        self.declare_parameter('forward_during_turn', 0.15)  # m/s (WAS 0.15)
        self.declare_parameter('max_turn_duration', 4.0)     # seconds (safety timeout)
        self.declare_parameter('line_reacquire_count', 3)    # frames of line detection = done

        self.x_tolerance = self.get_parameter('x_tolerance').value
        self.y_tolerance = self.get_parameter('y_tolerance').value
        self.turn_speed = self.get_parameter('turn_speed').value
        self.forward_speed = self.get_parameter('forward_during_turn').value
        self.max_turn_duration = self.get_parameter('max_turn_duration').value
        self.line_reacquire_count = self.get_parameter('line_reacquire_count').value

        # --- State ---
        self.agv_state = 'IDLE'
        self.target_shelf = None
        self.target_aisle_x = None
        self.x = 0.0
        self.y = 0.0
        self.yaw = 0.0

        self.turning = False
        self.turn_attempted_going = False
        self.turn_attempted_returning = False
        self.turn_start_time = None
        self.turn_direction = 0
        self.line_detect_frames = 0  # counts consecutive frames with line detected during turn

        # Sensor readings (from line_follower_node's junction detection)
        self.current_sensors = [0.0] * 8
        self.junction_detected_by_sensors = False

        # --- Subscribers ---
        self.create_subscription(Odometry, '/agv/odom', self.odom_cb, 10)
        self.create_subscription(AGVState, '/agv/state', self.state_cb, 10)
        self.create_subscription(Float32MultiArray, '/agv/line_sensors', self.sensors_cb, 10)
        self.create_subscription(Bool, '/agv/junction_detected', self.junction_cb, 10)

        # --- Publishers ---
        self.cmd_pub = self.create_publisher(Twist, '/agv/cmd_vel', 10)
        self.lf_enable_pub = self.create_publisher(Bool, '/agv/line_follow_enable', 10)
        self.turn_done_pub = self.create_publisher(Bool, '/agv/junction_turn_done', 10)

        # --- Control loop at 20 Hz ---
        self.create_timer(0.05, self.control_loop)

        self.get_logger().info('🧭 Junction Handler Node (FIXED) started')
        self.get_logger().info(
            f'   x_tol={self.x_tolerance:.2f} y_tol={self.y_tolerance:.2f} '
            f'turn_speed={self.turn_speed:.2f}'
        )

    # ============================== Callbacks ==============================

    def odom_cb(self, msg: Odometry):
        self.x = msg.pose.pose.position.x
        self.y = msg.pose.pose.position.y
        self.yaw = yaw_from_quat(msg.pose.pose.orientation)

    def state_cb(self, msg: AGVState):
        new_state = msg.state
        if new_state != self.agv_state:
            self.get_logger().info(f'🧭 AGV state change: {self.agv_state} → {new_state}')
            self.agv_state = new_state

            # Reset turn flags when entering a new mission phase
            if new_state == 'GOING':
                self.turn_attempted_going = False
            elif new_state == 'RETURNING':
                self.turn_attempted_returning = False

        # Update target info
        if msg.current_target and msg.current_target in SHELF_MAP:
            self.target_shelf = msg.current_target
            self.target_aisle_x = SHELF_MAP[msg.current_target]['aisle_x']
        else:
            self.target_shelf = None
            self.target_aisle_x = None

    def sensors_cb(self, msg: Float32MultiArray):
        if len(msg.data) >= 8:
            self.current_sensors = list(msg.data)

    def junction_cb(self, msg: Bool):
        """Fired by line_follower_node when 5+ sensors see black."""
        if msg.data:
            self.junction_detected_by_sensors = True
        # We'll consume this flag in control_loop and reset it

    # ============================== Control Loop ==============================

    def control_loop(self):
        # --- If currently executing a turn ---
        if self.turning:
            self.execute_turn()
            return

        # --- Check if we should START a turn ---

        # GOING: Turn into spur
        if (self.agv_state == 'GOING'
                and not self.turn_attempted_going
                and self.target_aisle_x is not None):

            should_turn = self.check_junction_going()
            if should_turn:
                self.get_logger().info(
                    f'🧭 ✅ JUNCTION TRIGGERED for {self.target_shelf}!'
                    f' AGV at ({self.x:.2f}, {self.y:.2f}), '
                    f'target aisle_x={self.target_aisle_x:.2f}'
                )
                self.begin_turn(direction=+1)  # +1 = turn LEFT into spur
                self.turn_attempted_going = True

        # RETURNING: Turn back onto main aisle
        elif (self.agv_state == 'RETURNING'
                and not self.turn_attempted_returning
                and self.target_aisle_x is not None):

            should_turn = self.check_junction_returning()
            if should_turn:
                self.get_logger().info(
                    f'🧭 ✅ RETURN JUNCTION TRIGGERED!'
                    f' AGV at ({self.x:.2f}, {self.y:.2f})'
                )
                # When returning, the AGV is facing -Y (back toward main aisle)
                # It needs to turn LEFT (which in world frame is toward -X or +X
                # depending on which side)
                self.begin_turn(direction=-1)  # -1 = turn RIGHT onto main aisle
                self.turn_attempted_returning = True

        # Reset the junction sensor flag every loop
        self.junction_detected_by_sensors = False

    # ============================== Junction Detection ==============================

    def check_junction_going(self) -> bool:
        """
        Should we turn? Two conditions must BOTH be true:
          1. AGV is roughly on the main aisle (Y close to 0)
          2. AGV's X is close to the target aisle's X
        
        OR: The optical sensors detected a junction (5+ black) AND
            we're close to the target X.
        """
        # Condition 1: Y is near main aisle
        on_main_aisle = abs(self.y) < self.y_tolerance

        # Condition 2: X is near target spur
        near_target_x = abs(self.x - self.target_aisle_x) < self.x_tolerance

        # Method A: Pure position-based
        if on_main_aisle and near_target_x:
            self.get_logger().info(
                f'🧭 Junction check PASSED (position): '
                f'y={self.y:.2f} (tol={self.y_tolerance}), '
                f'x={self.x:.2f} vs target={self.target_aisle_x:.2f} (tol={self.x_tolerance})'
            )
            return True

        # Method B: Sensor-based (5+ sensors see black) + rough X match
        if self.junction_detected_by_sensors and near_target_x:
            self.get_logger().info(
                f'🧭 Junction check PASSED (sensor): '
                f'sensors saw junction AND x={self.x:.2f} near target={self.target_aisle_x:.2f}'
            )
            return True

        return False

    def check_junction_returning(self) -> bool:
        """
        When returning, the AGV is on a spur heading toward Y=0.
        We want to turn when it reaches the main aisle.
        """
        # Simple: when Y gets close to 0, it's back at main aisle level
        near_main = abs(self.y) < 0.30
        # Also check X is still near the spur (sanity)
        near_spur_x = abs(self.x - self.target_aisle_x) < self.x_tolerance

        if near_main and near_spur_x:
            self.get_logger().info(
                f'🧭 Return junction: y={self.y:.2f} is near main aisle'
            )
            return True

        return False

    # ============================== Turn Execution ==============================

    def begin_turn(self, direction):
        """
        Start a turn:
          direction = +1 → turn LEFT (positive angular.z)
          direction = -1 → turn RIGHT (negative angular.z)
        """
        # Disable the line follower (we're taking manual control)
        msg = Bool()
        msg.data = False
        self.lf_enable_pub.publish(msg)

        self.turning = True
        self.turn_direction = direction
        self.turn_start_time = self.get_clock().now()
        self.line_detect_frames = 0

        self.get_logger().info(
            f'🧭 Turn started (direction={"LEFT" if direction > 0 else "RIGHT"}). '
            f'Line follower DISABLED.'
        )

    def execute_turn(self):
        """
        Called every 50ms while turning.
        Strategy: drive forward slowly while turning, until either:
          (a) The sensors detect a new line (= we've aligned with the spur), OR
          (b) Safety timeout expires (max_turn_duration seconds)
        """
        elapsed = (self.get_clock().now() - self.turn_start_time).nanoseconds / 1e9

        # Safety: if we've been turning too long, something's wrong — abort
        if elapsed > self.max_turn_duration:
            self.get_logger().warn(
                f'🧭 ⚠️ Turn TIMEOUT after {elapsed:.1f}s. Stopping and re-enabling line follower.'
            )
            self.finish_turn()
            return

        # During the first 0.5 seconds, just turn blindly (to get OFF the current line)
        # After that, start watching sensors for the new line
        if elapsed > 0.5:
            # Check if sensors see a line (specifically: 1-3 sensors = normal line)
            black_count = sum(1 for s in self.current_sensors if s > 0.5)

            if 1 <= black_count <= 4:
                # Sensors see a line but not a junction — we've found the spur!
                self.line_detect_frames += 1
            else:
                self.line_detect_frames = 0

            # Need N consecutive frames of "line found" to confirm
            if self.line_detect_frames >= self.line_reacquire_count:
                self.get_logger().info(
                    f'🧭 ✅ Spur line reacquired after {elapsed:.1f}s! Turn complete.'
                )
                self.finish_turn()
                return

        # Still turning: publish turn command
        twist = Twist()
        twist.linear.x = self.forward_speed
        twist.angular.z = self.turn_speed * self.turn_direction
        self.cmd_pub.publish(twist)

    def finish_turn(self):
        """Stop the turn and hand control back to line follower."""
        # Stop briefly
        self.cmd_pub.publish(Twist())
        self.turning = False

        # Re-enable line follower
        enable_msg = Bool()
        enable_msg.data = True
        self.lf_enable_pub.publish(enable_msg)

        # Publish turn done signal
        done_msg = Bool()
        done_msg.data = True
        self.turn_done_pub.publish(done_msg)

        self.get_logger().info('🧭 Turn done. Line follower RE-ENABLED.')


def main(args=None):
    rclpy.init(args=args)
    node = JunctionHandlerNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
