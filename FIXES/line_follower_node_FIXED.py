#!/usr/bin/env python3
"""
Line Follower Node (optical sensor version) — FIXED
----------------------------------------------------
FIXES APPLIED:
  1. Removed the insane '* 100.0' scaling on offset
  2. Recalibrated PID gains for [-1, +1] offset range
  3. Increased linear_speed to 0.50 m/s (warehouse is 15m long)
  4. Added junction detection (5+ sensors black = junction)
  5. Added debug logging so you can SEE what's happening

Subscribes to /agv/line_sensors (8 binary values from optical_sensor_node),
computes the line offset, runs PID, and publishes /agv/cmd_vel.
"""

import rclpy
from rclpy.node import Node

from std_msgs.msg import Bool, Float32MultiArray
from geometry_msgs.msg import Twist

import numpy as np


class LineFollowerNode(Node):

    def __init__(self):
        super().__init__('line_follower_node')

        # ---------------- Parameters ----------------
        self.declare_parameter('linear_speed', 0.50)   # ← WAS 0.30, NOW 0.50
        self.declare_parameter('kp', 0.50)             # ← WAS 0.012
        self.declare_parameter('ki', 0.00)             # ← same (keep at 0)
        self.declare_parameter('kd', 0.15)             # ← WAS 0.004
        self.declare_parameter('enabled', True)

        self.linear_speed = self.get_parameter('linear_speed').value
        self.kp           = self.get_parameter('kp').value
        self.ki           = self.get_parameter('ki').value
        self.kd           = self.get_parameter('kd').value
        self.enabled      = self.get_parameter('enabled').value

        # ---------------- PID State ----------------
        self.prev_error      = 0.0
        self.integral        = 0.0
        self.last_offset     = 0.0
        self.line_lost_count = 0
        self.MAX_LOST_FRAMES = 25   # ← increased from 15 (at 50 Hz = 0.5 sec grace)

        # ---------------- Junction detection ----------------
        self.junction_threshold = 5  # 5+ sensors black = junction
        self.junction_pub = None     # will create below

        # ---------------- Subscriptions ----------------
        self.create_subscription(
            Float32MultiArray, '/agv/line_sensors',
            self.sensors_callback, 10
        )
        self.create_subscription(
            Bool, '/agv/line_follow_enable',
            self.enable_callback, 10
        )

        # ---------------- Publishers ----------------
        self.cmd_pub = self.create_publisher(Twist, '/agv/cmd_vel', 10)
        self.junction_pub = self.create_publisher(
            Bool, '/agv/junction_detected', 10
        )

        # Debug counter (log every 50th frame so terminal isn't flooded)
        self.frame_count = 0

        self.get_logger().info('🚀 Line Follower Node (FIXED) started')
        self.get_logger().info(
            f'   linear_speed={self.linear_speed:.2f}  '
            f'kp={self.kp:.3f}  ki={self.ki:.3f}  kd={self.kd:.3f}'
        )

    # ==========================================================
    def enable_callback(self, msg: Bool):
        self.enabled = msg.data
        state = "ENABLED" if self.enabled else "DISABLED"
        self.get_logger().info(f'🔧 Line follower {state}')
        if not self.enabled:
            self.cmd_pub.publish(Twist())  # stop
            # Reset PID when disabled so it doesn't accumulate stale error
            self.prev_error = 0.0
            self.integral = 0.0

    # ==========================================================
    def sensors_callback(self, msg: Float32MultiArray):
        if not self.enabled:
            return
        if len(msg.data) < 8:
            return

        binary = np.array(msg.data, dtype=np.float32)

        # --- Junction detection ---
        black_count = int(binary.sum())
        if black_count >= self.junction_threshold:
            jmsg = Bool()
            jmsg.data = True
            self.junction_pub.publish(jmsg)

        # --- Compute offset ---
        offset, line_detected = self.compute_offset(binary)

        # --- PID control ---
        if line_detected:
            self.line_lost_count = 0
            angular_z = self.pid_step(offset)
            linear_x  = self.linear_speed
            self.last_offset = offset
        else:
            self.line_lost_count += 1
            if self.line_lost_count < self.MAX_LOST_FRAMES:
                # Grace period — slow down and use last known correction
                angular_z = self.pid_step(self.last_offset) * 0.3
                linear_x  = self.linear_speed * 0.3
            else:
                angular_z = 0.0
                linear_x  = 0.0
                if self.line_lost_count == self.MAX_LOST_FRAMES:
                    self.get_logger().warn('⚠️  Line lost! Stopping.')

        # --- Publish velocity ---
        twist = Twist()
        twist.linear.x  = float(linear_x)
        twist.angular.z = float(angular_z)
        self.cmd_pub.publish(twist)

        # --- Debug logging (every 2 seconds) ---
        self.frame_count += 1
        if self.frame_count % 100 == 0:
            binary_str = ''.join(['■' if b > 0.5 else '□' for b in binary])
            self.get_logger().info(
                f'  [{binary_str}] offset={offset:+.3f} '
                f'ang_z={angular_z:+.3f} lin_x={linear_x:.2f}'
            )

    # ==========================================================
    def compute_offset(self, binary):
        """
        Weighted center-of-mass offset.

        Returns (offset, detected):
          offset: float in range [-1.0, +1.0]
                  -1 = line is at far LEFT
                  +1 = line is at far RIGHT
                   0 = line is centered
          detected: True if at least one sensor sees black
        """
        if binary.sum() == 0:
            return 0.0, False

        indices = np.arange(len(binary))
        center_of_mass = float((indices * binary).sum() / binary.sum())
        center_index = (len(binary) - 1) / 2.0   # = 3.5 for 8 sensors

        # Offset in range [-1, +1] — NO MORE * 100 !!!
        offset = (center_of_mass - center_index) / center_index
        return offset, True

    # ==========================================================
    def pid_step(self, error: float) -> float:
        """
        PID controller.
        Input: error in [-1, +1]
        Output: angular velocity command (rad/s)
        """
        self.integral += error
        # Anti-windup: clamp integral to prevent runaway
        self.integral = max(min(self.integral, 2.0), -2.0)

        derivative = error - self.prev_error
        output = (self.kp * error) + (self.ki * self.integral) + (self.kd * derivative)
        self.prev_error = error

        # Clamp output to reasonable angular velocity
        output = max(min(output, 1.5), -1.5)

        # Sign convention:
        # Positive error = line is to the RIGHT of center
        # We want to turn RIGHT = negative angular.z in ROS
        return -output


def main(args=None):
    rclpy.init(args=args)
    node = LineFollowerNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.cmd_pub.publish(Twist())
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
