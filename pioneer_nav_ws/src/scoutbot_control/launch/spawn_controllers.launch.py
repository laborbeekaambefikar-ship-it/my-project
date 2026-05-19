"""
spawn_controllers.launch.py
===========================
Spawns the two ros2_control controllers on the controller_manager that
gazebo_ros2_control creates inside Gazebo. Uses an event chain so that:

    joint_state_broadcaster spawn   ->   ON EXIT   ->   diff_drive spawn

This sequencing prevents the previous project's "controller stuck in
waiting" failure: the diff-drive spawner is never invoked until the
joint_state_broadcaster spawner has fully exited (which itself only exits
once the controller_manager has accepted the load+activate request).

Both spawners reach the controller_manager via the namespaced service
``/scoutbot/controller_manager/...``; we set ``--controller-manager``
explicitly to make this unambiguous.
"""

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, RegisterEventHandler
from launch.event_handlers import OnProcessExit
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def generate_launch_description() -> LaunchDescription:
    arg_cm_ns = DeclareLaunchArgument(
        'controller_manager_ns',
        default_value='/scoutbot/controller_manager',
        description='Fully-qualified controller_manager service namespace.',
    )

    # Spawner #1: joint_state_broadcaster -- must come first so subsequent
    # controllers can rely on a /joint_states topic for diagnostics.
    spawn_jsb = Node(
        package='controller_manager',
        executable='spawner',
        name='spawn_scoutbot_joint_broadcaster',
        arguments=[
            'scoutbot_joint_broadcaster',
            '--controller-manager', LaunchConfiguration('controller_manager_ns'),
        ],
        output='screen',
    )

    # Spawner #2: diff_drive_controller -- only fires AFTER spawner #1 exits.
    spawn_dd = Node(
        package='controller_manager',
        executable='spawner',
        name='spawn_scoutbot_base_controller',
        arguments=[
            'scoutbot_base_controller',
            '--controller-manager', LaunchConfiguration('controller_manager_ns'),
        ],
        output='screen',
    )

    chain = RegisterEventHandler(
        OnProcessExit(target_action=spawn_jsb, on_exit=[spawn_dd])
    )

    return LaunchDescription([arg_cm_ns, spawn_jsb, chain])
