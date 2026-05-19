"""
scout_full_stack.launch.py
==========================
The single launch file most users invoke. Composes:

    1. start_world.launch.py        (Gazebo + flat_arena.world)
    2. spawn_robot.launch.py        (RSP + spawn_entity, gated)
    3. spawn_controllers.launch.py  (joint_broadcaster -> diff_drive)
    4. start_navigator.launch.py    (waypoint state machine + diagnostics)

The whole chain is brought up with a single command::

    ros2 launch scoutbot_bringup scout_full_stack.launch.py

Optional args
-------------
* gui            true|false   (Gazebo GUI)
* x, y, yaw      initial pose
* waypoints_yaml absolute path to a custom mission file
"""

from launch import LaunchDescription
from launch.actions import (
    DeclareLaunchArgument, IncludeLaunchDescription,
    RegisterEventHandler, TimerAction,
)
from launch.event_handlers import OnProcessStart
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration, PathJoinSubstitution
from launch_ros.actions import Node
from launch_ros.substitutions import FindPackageShare


def generate_launch_description() -> LaunchDescription:
    # ---- args ----------------------------------------------------------------
    arg_gui   = DeclareLaunchArgument('gui',   default_value='true',
                                      description='Run gzclient (Gazebo GUI).')
    arg_sim   = DeclareLaunchArgument('use_sim_time', default_value='true',
                                      description='Use Gazebo /clock for time.')
    arg_x     = DeclareLaunchArgument('x',     default_value='0.0')
    arg_y     = DeclareLaunchArgument('y',     default_value='0.0')
    arg_yaw   = DeclareLaunchArgument('yaw',   default_value='0.0')
    arg_wp    = DeclareLaunchArgument(
        'waypoints_yaml',
        default_value=PathJoinSubstitution([
            FindPackageShare('scoutbot_navigator'),
            'config', 'waypoints.yaml',
        ]),
        description='Mission file used by the waypoint navigator.',
    )
    arg_nav_delay = DeclareLaunchArgument(
        'navigator_delay', default_value='8.0',
        description=('Seconds to wait after launch start before the navigator '
                     'is started. Gives Gazebo + spawn_entity + controllers '
                     'time to come up so the first /scoutbot/odom message '
                     'has been published.'),
    )

    # ---- 1. Gazebo + world ---------------------------------------------------
    world_launch = IncludeLaunchDescription(
        PythonLaunchDescriptionSource([
            PathJoinSubstitution([
                FindPackageShare('scoutbot_simulation'),
                'launch', 'start_world.launch.py',
            ]),
        ]),
        launch_arguments={
            'gui':     LaunchConfiguration('gui'),
            'verbose': 'true',
        }.items(),
    )

    # ---- 2. RSP + spawn_entity (already gated by its own event handler) -----
    spawn_launch = IncludeLaunchDescription(
        PythonLaunchDescriptionSource([
            PathJoinSubstitution([
                FindPackageShare('scoutbot_simulation'),
                'launch', 'spawn_robot.launch.py',
            ]),
        ]),
        launch_arguments={
            'x':            LaunchConfiguration('x'),
            'y':            LaunchConfiguration('y'),
            'yaw':          LaunchConfiguration('yaw'),
            'use_sim_time': LaunchConfiguration('use_sim_time'),
        }.items(),
    )

    # ---- 3. Controller spawners (chained: jsb -> diff_drive) ----------------
    # Wrapped in a 4 s timer so the controller_manager (which is born inside
    # Gazebo by the gazebo_ros2_control plugin) has had time to advertise its
    # services. This is belt-and-braces on top of the spawner's built-in
    # "wait for service" logic.
    controllers_include = IncludeLaunchDescription(
        PythonLaunchDescriptionSource([
            PathJoinSubstitution([
                FindPackageShare('scoutbot_control'),
                'launch', 'spawn_controllers.launch.py',
            ]),
        ]),
    )
    controllers_after_spawn = TimerAction(period=4.0, actions=[controllers_include])

    # ---- 4. Navigator (delayed so controllers + odom are up) ----------------
    navigator_include = IncludeLaunchDescription(
        PythonLaunchDescriptionSource([
            PathJoinSubstitution([
                FindPackageShare('scoutbot_navigator'),
                'launch', 'start_navigator.launch.py',
            ]),
        ]),
        launch_arguments={
            'waypoints_yaml': LaunchConfiguration('waypoints_yaml'),
            'use_sim_time':   LaunchConfiguration('use_sim_time'),
        }.items(),
    )
    navigator_delayed = TimerAction(
        period=8.0,
        actions=[navigator_include],
    )

    return LaunchDescription([
        arg_gui, arg_sim, arg_x, arg_y, arg_yaw, arg_wp, arg_nav_delay,
        world_launch,
        spawn_launch,
        controllers_after_spawn,
        navigator_delayed,
    ])
