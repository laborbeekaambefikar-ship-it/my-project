"""
start_world.launch.py
=====================
Launches Gazebo Classic 11 with the flat_arena.world. No robot is spawned
here -- that is the responsibility of spawn_robot.launch.py / scout_full_stack.

  ros2 launch scoutbot_simulation start_world.launch.py
  ros2 launch scoutbot_simulation start_world.launch.py gui:=false   # headless
"""

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, IncludeLaunchDescription
from launch.conditions import IfCondition
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration, PathJoinSubstitution
from launch_ros.substitutions import FindPackageShare


def generate_launch_description() -> LaunchDescription:
    arg_world = DeclareLaunchArgument(
        'world',
        default_value=PathJoinSubstitution([
            FindPackageShare('scoutbot_simulation'),
            'worlds', 'flat_arena.world',
        ]),
        description='Absolute path to the .world file Gazebo should load.',
    )
    arg_gui = DeclareLaunchArgument(
        'gui', default_value='true',
        description='If false, run headless (no gzclient).',
    )
    arg_verbose = DeclareLaunchArgument(
        'verbose', default_value='true',
        description='Pass --verbose to gzserver/gzclient for diagnostics.',
    )

    # Compose with the upstream gazebo_ros launch files; this is the
    # idiomatic ROS 2 way and gives us /clock, /spawn_entity, etc. for free.
    gz_server = IncludeLaunchDescription(
        PythonLaunchDescriptionSource([
            PathJoinSubstitution([
                FindPackageShare('gazebo_ros'), 'launch', 'gzserver.launch.py',
            ]),
        ]),
        launch_arguments={
            'world':   LaunchConfiguration('world'),
            'verbose': LaunchConfiguration('verbose'),
        }.items(),
    )

    gz_client = IncludeLaunchDescription(
        PythonLaunchDescriptionSource([
            PathJoinSubstitution([
                FindPackageShare('gazebo_ros'), 'launch', 'gzclient.launch.py',
            ]),
        ]),
        launch_arguments={
            'verbose': LaunchConfiguration('verbose'),
        }.items(),
        condition=IfCondition(LaunchConfiguration('gui')),
    )

    return LaunchDescription([arg_world, arg_gui, arg_verbose, gz_server, gz_client])
