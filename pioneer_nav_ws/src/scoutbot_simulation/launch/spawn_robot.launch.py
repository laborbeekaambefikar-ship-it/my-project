"""
spawn_robot.launch.py
=====================
Publishes /robot_description (xacro -> URDF) via robot_state_publisher and
spawns the scoutbot into a *running* Gazebo. Spawn is gated on RSP being
alive AND a 2 s warmup so /robot_description has settled - this is the
structural fix for the previous project's spawn-time race conditions.

Inputs
------
* x, y, yaw  - initial pose in scout_odom (defaults: 0 0 0)
* use_sim_time - propagated to RSP

Order of operations
-------------------
1. robot_state_publisher publishes /robot_description (xacro string).
2. After RSP starts AND 2 s elapse, spawn_entity.py is invoked with
   ``-topic /robot_description`` so any xacro syntax error surfaces at
   step (1) -- not silently here at step (2).
3. The gazebo_ros2_control plugin embedded in the URDF loads
   controllers.yaml inside Gazebo and creates /scoutbot/controller_manager.
4. The controller spawners are launched by the higher-level bringup; this
   file only handles RSP + spawn_entity.
"""

from launch import LaunchDescription
from launch.actions import (
    DeclareLaunchArgument, RegisterEventHandler, TimerAction,
)
from launch.event_handlers import OnProcessStart
from launch.substitutions import (
    Command, FindExecutable, LaunchConfiguration, PathJoinSubstitution,
)
from launch_ros.actions import Node
from launch_ros.substitutions import FindPackageShare


def generate_launch_description() -> LaunchDescription:
    # ---- launch arguments ----------------------------------------------------
    arg_x   = DeclareLaunchArgument('x',   default_value='0.0',
                                    description='Initial X in scout_odom [m].')
    arg_y   = DeclareLaunchArgument('y',   default_value='0.0',
                                    description='Initial Y in scout_odom [m].')
    arg_yaw = DeclareLaunchArgument('yaw', default_value='0.0',
                                    description='Initial yaw [rad].')
    arg_sim = DeclareLaunchArgument('use_sim_time', default_value='true',
                                    description='Use Gazebo /clock for time.')
    arg_robot_name = DeclareLaunchArgument(
        'robot_name', default_value='scoutbot',
        description='Entity name passed to /spawn_entity.',
    )

    # ---- xacro -> URDF string ------------------------------------------------
    urdf_path = PathJoinSubstitution([
        FindPackageShare('scoutbot_description'),
        'urdf', 'scoutbot.urdf.xacro',
    ])
    controllers_yaml = PathJoinSubstitution([
        FindPackageShare('scoutbot_control'),
        'config', 'controllers.yaml',
    ])
    robot_description_cmd = Command([
        FindExecutable(name='xacro'), ' ', urdf_path,
        ' controllers_yaml:=', controllers_yaml,
    ])
    robot_description = {'robot_description': robot_description_cmd}

    # ---- robot_state_publisher (publishes /robot_description) ---------------
    rsp = Node(
        package='robot_state_publisher',
        executable='robot_state_publisher',
        name='robot_state_publisher',
        output='screen',
        parameters=[
            robot_description,
            {'use_sim_time': LaunchConfiguration('use_sim_time')},
        ],
    )

    # ---- spawn_entity (runs ONCE, gated on RSP being alive) -----------------
    spawn = Node(
        package='gazebo_ros',
        executable='spawn_entity.py',
        name='spawn_scoutbot',
        output='screen',
        arguments=[
            '-topic',  '/robot_description',
            '-entity', LaunchConfiguration('robot_name'),
            '-x',      LaunchConfiguration('x'),
            '-y',      LaunchConfiguration('y'),
            '-z',      '0.05',
            '-Y',      LaunchConfiguration('yaw'),
        ],
    )

    # The RegisterEventHandler ensures spawn is triggered only AFTER RSP starts;
    # the TimerAction(2.0) gives RSP enough time to actually publish the topic.
    spawn_after_rsp = RegisterEventHandler(
        OnProcessStart(
            target_action=rsp,
            on_start=[TimerAction(period=2.0, actions=[spawn])],
        ),
    )

    return LaunchDescription([
        arg_x, arg_y, arg_yaw, arg_sim, arg_robot_name,
        rsp,
        spawn_after_rsp,
    ])
