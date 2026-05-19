"""
diagnostic_node.py
==================
Minimal subscriber that pretty-prints /scoutbot/nav_status to stdout.
Useful for terminal-only debugging without launching RViz.

  ros2 run scoutbot_navigator nav_diagnostics
"""

from __future__ import annotations

import math

import rclpy
from rclpy.node import Node

from scoutbot_interfaces.msg import NavigationStatus


class NavDiagnosticsNode(Node):
    def __init__(self) -> None:
        super().__init__('nav_diagnostics')
        self.declare_parameter('status_topic', '/scoutbot/nav_status')
        topic = self.get_parameter('status_topic').value
        self._sub = self.create_subscription(
            NavigationStatus, topic, self._on_status, 10
        )
        self.get_logger().info(f'nav_diagnostics listening on {topic}')

    def _on_status(self, msg: NavigationStatus) -> None:
        self.get_logger().info(
            f'state={msg.state:<14s} '
            f'wp={msg.current_waypoint_index+1}/{msg.total_waypoints} '
            f'd={msg.distance_to_goal:.2f}m '
            f'he={math.degrees(msg.heading_error):+6.1f}deg '
            f'v={msg.cmd_linear_velocity:+.2f} '
            f'w={msg.cmd_angular_velocity:+.2f} '
            f'active={msg.is_active}'
        )


def main(args=None) -> None:
    rclpy.init(args=args)
    node = NavDiagnosticsNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
