"""
start_navigator.launch.py
=========================
Brings up the waypoint_navigator node alone -- assumes the simulator and
controllers are already running. Useful for iterative gain tuning.

  ros2 launch scoutbot_navigator start_navigator.launch.py

Optional args
-------------
* waypoints_yaml   absolute path to a waypoints YAML; default = the one
                   shipped in this package.
* gains_yaml       absolute path to pid_gains.yaml from scoutbot_control;
                   defaults to the package's installed copy.
"""

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration, PathJoinSubstitution
from launch_ros.actions import Node
from launch_ros.substitutions import FindPackageShare


def generate_launch_description() -> LaunchDescription:
    default_waypoints = PathJoinSubstitution([
        FindPackageShare('scoutbot_navigator'), 'config', 'waypoints.yaml',
    ])
    default_gains = PathJoinSubstitution([
        FindPackageShare('scoutbot_control'), 'config', 'pid_gains.yaml',
    ])

    arg_wp    = DeclareLaunchArgument('waypoints_yaml', default_value=default_waypoints,
                                      description='Path to waypoints YAML.')
    arg_gains = DeclareLaunchArgument('gains_yaml', default_value=default_gains,
                                      description='Path to pid_gains.yaml.')
    arg_sim   = DeclareLaunchArgument('use_sim_time', default_value='true',
                                      description='Use Gazebo /clock for time.')

    navigator = Node(
        package='scoutbot_navigator',
        executable='waypoint_navigator',
        name='waypoint_navigator',
        output='screen',
        parameters=[
            LaunchConfiguration('gains_yaml'),
            {
                'use_sim_time':    LaunchConfiguration('use_sim_time'),
                'waypoints_yaml':  LaunchConfiguration('waypoints_yaml'),
            },
        ],
    )

    diagnostics = Node(
        package='scoutbot_navigator',
        executable='nav_diagnostics',
        name='nav_diagnostics',
        output='screen',
        parameters=[{'use_sim_time': LaunchConfiguration('use_sim_time')}],
    )

    return LaunchDescription([arg_wp, arg_gains, arg_sim, navigator, diagnostics])
